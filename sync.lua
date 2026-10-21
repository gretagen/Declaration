-- Install prefix, overridable so a working tree can be tested without a
-- repack (NACELLE_LIB=/home/gretagen/nacelle ./nacelle spin system).
local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

package.path = LIB .. "/?.lua;" .. LIB .. "/generators/?.lua;" .. package.path

-- Which generators run is decided by /etc/nacelle/enabled_modules.lua
-- (see plugins.lua); sync.lua does not own that list.
local enabled_generators = require("plugins").enabled_generators()

local config = require("config")

local sync = {}

-- repower mode: --repower exports NACELLE_REPOWER=1 and every "already
-- satisfied" gate is bypassed, so the run reapplies and rebuilds everything
-- even on a converged system (nixos-rebuild switch style). Detection reads
-- stay untouched: generators still parse what is on disk, they just never
-- short-circuit to "no change".
sync.repower = os.getenv("NACELLE_REPOWER") ~= nil

-- single gate helper used by every generator equality check
function sync.differs(current, desired)
  if sync.repower then return true end
  return current ~= desired
end

-- verbose diagnostics: silent unless the CLI passed --verbose (which exports
-- NACELLE_VERBOSE=1). Errors never travel through vprint: generator load
-- failures and planner crashes are written straight to stderr so a normal
-- run still shows them.
local VERBOSE = os.getenv("NACELLE_VERBOSE") ~= nil

function sync.vprint(...)
  if not VERBOSE then return end
  io.stderr:write("[v] ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

function sync.eprint(fmt, ...)
  io.stderr:write("[error] ")
  io.stderr:write(string.format(fmt, ...))
  io.stderr:write("\n")
end

-- file I/O helpers
function sync.read_file(path)
  sync.vprint("read_file %s", path)
  local f, err = io.open(path, "r")
  if not f then
    sync.vprint("  → not found")
    return nil
  end
  local c = f:read("*a")
  f:close()
  sync.vprint("  → %d bytes", #c)
  return c
end

function sync.ensure_dir(dir)
  local f = io.open(dir, "r")
  if f then f:close(); return true end
  io.stderr:write("[warn] creating directory: " .. dir .. "\n")
  return sync.shell("mkdir -p '" .. dir .. "'")
end

function sync.write_file(path, content)
  sync.vprint("write_file %s (%d bytes)", path, #content)
  local dir = path:match("^(.*/)")
  if dir then
    local ok = sync.ensure_dir(dir)
    if not ok then return false, "failed to create " .. dir end
  end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- shell helpers
function sync.shell(cmd)
  sync.vprint("shell: %s", cmd)
  local ok = os.execute(cmd)
  if type(ok) == "number" then
    sync.vprint("  → exit %d", ok)
    return ok == 0
  end
  sync.vprint("  → %s", tostring(ok))
  return ok or false
end

function sync.shell_output(cmd)
  sync.vprint("shell_output: %s", cmd)
  local f = io.popen(cmd .. " 2>/dev/null", "r")
  if not f then
    sync.vprint("  → (popen failed)")
    return ""
  end
  local out = f:read("*a")
  f:close()
  local result = (out or ""):gsub("%s+$", "")
  sync.vprint("  → [%s]", result)
  return result
end

-- diff entry constructor
function sync.change(typ, section, target, detail, apply)
  return { type = typ, section = section, target = target, detail = detail, apply_fn = apply }
end

-- load generators
--
-- Order matters within a change type: subspaces must come before
-- subspaces_packages and merged_packages, because those two install into or
-- merge from a subspace that has to exist first. The sort in sync.collect is
-- stable (it breaks ties on collection order), so this list is respected.
local generators = {}


sync.vprint("loading generators...")
for _, name in ipairs(enabled_generators) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    sync.vprint("  generator '%s' loaded", name)
  else
    -- always visible: a silently dropped generator would make the sync
    -- report success while planning with a smaller set than the config asks
    sync.eprint("generator '%s' failed to load: %s", name, tostring(gen))
  end
end
sync.vprint("%d generators loaded", #generators)

-- collect all changes
function sync.collect(cfg)
  local changes = {}
  local seq = 0
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, sync)
    if ok and plans then
      sync.vprint("  → %d changes", #plans)
      for _, c in ipairs(plans) do
        seq = seq + 1
        c.seq = seq
        table.insert(changes, c)
      end
    else
      -- always visible, same reason as a failed load: the plan is incomplete
      sync.eprint("planner '%s' crashed: %s", name, tostring(plans))
    end
  end
  -- Group by type (+ before ~ before -) so a package swap installs the
  -- replacement before removing the original. Ties break on collection order:
  -- table.sort is not stable, so without an explicit tiebreaker the order
  -- within a group would be arbitrary and a subspace could be used before the
  -- change that creates it is applied.
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    local oa, ob = order[a.type] or 0, order[b.type] or 0
    if oa ~= ob then
      return oa < ob
    end
    return a.seq < b.seq
  end)
  sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function sync.summary(changes)
  if #changes == 0 then
    print("System seems to be already synchronized, no changes required.")
    return
  end
  local groups = {}
  for _, c in ipairs(changes) do
    local s = c.section or "misc"
    if not groups[s] then groups[s] = {} end
    table.insert(groups[s], c)
  end
  print()
  print("  System Synchronization plan : ")
  print("  " .. string.rep("=", 40))
  if sync.repower then
    print("  mode: repower (reapplying and rebuilding everything)")
  end
  print()
  for s, entries in pairs(groups) do
    print("  [" .. s .. "]")
    for _, c in ipairs(entries) do
      local sym = c.type == "+" and " [+] " or c.type == "-" and " [-] " or " [~] "
      print("    " .. sym .. c.target)
      if c.detail then
        print("         " .. c.detail)
      end
    end
    print()
  end
end

-- apply all changes
function sync.apply(changes)
  local failures = 0
  local merged_applied = false
  for _, c in ipairs(changes) do
    local sym = c.type == "+" and "[+]" or c.type == "-" and "[-]" or "[~]"
    io.stderr:write(string.format("[apply] %s %s/%s\n", sym, c.section or "?", c.target))
    if c.apply_fn then
      local ok, result = pcall(c.apply_fn, c, sync)
      if not ok then
        io.stderr:write("[error] " .. tostring(result) .. "\n")
        failures = failures + 1
      elseif result == false then
        io.stderr:write("[error] command failed\n")
        failures = failures + 1
      else
        io.stderr:write("[ok] " .. sym .. " " .. (c.section or "?") .. "/" .. c.target .. "\n")
        if (c.section or ""):match("^merged%-packages") then
          merged_applied = true
        end
      end
    end
  end
  -- Post-merge hooks (desktop/icon/font caches, ldconfig, wayland pruning)
  -- live on the merged_packages generator: run them once, after every merge
  -- change landed, so a rebuild leaves the host caches consistent.
  if merged_applied then
    for _, gen in ipairs(generators) do
      if type(gen.post_merge) == "function" then
        local ok, err = pcall(gen.post_merge, sync)
        if not ok then
          io.stderr:write("[error] post_merge: " .. tostring(err) .. "\n")
        end
      end
    end
  end
  if failures > 0 then
    io.stderr:write(string.format("\n[warn] %d change(s) failed : review errors above\n", failures))
  end
  return true, failures
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("sync%.lua$") then
  local uid = tonumber((sync.shell_output("id -u")))
  if uid ~= 0 then
    io.stderr:write("error: root privileges required\n")
    os.exit(1)
  end

  local cfg_path = arg[1] or "/etc/nacelle/definition.lua"
  sync.vprint("loading config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end
  sync.vprint("config loaded: hostname=%s, timezone=%s, packages=%d/%d, services=%d/%d/%d",
    cfg.hostname, cfg.timezone,
    #(cfg["packages-haliade"] or {}), #(cfg["packages-isolated"] or {}),
    #(cfg["rc-services"] or {}), #(cfg["runit-services"] or {}), #(cfg["dinit-services"] or {}))

  local changes = sync.collect(cfg)
  sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  io.write("Synchronize system? [y/N]: ")
  io.flush()
  local answer = io.read()
  local ok = answer and (answer:lower() == "y" or answer:lower() == "yes")
  if not ok then
    print("Cancelled.")
    os.exit(0)
  end

  print("Applying changes...")
  local _, failures = sync.apply(changes)
  if failures and failures > 0 then
    print("Synchronization finished with " .. failures .. " failure(s).")
    io.stderr:write("No new generation has been created : fix errors first.\n")
  else
    print("Creating post-sync generation...")
    local label = sync.repower and "post-repower" or "post-sync"
    if not sync.shell("chronos create '" .. label .. "'") then
      io.stderr:write("[warn] chronos create failed : system is synced but no new boot entry was added.\n")
      io.stderr:write("        Check btrfs layout (@ / @snapshots) and run: chronos create '" .. label .. "'\n")
    end
    print("Synchronization completed.")
  end
end



return sync
