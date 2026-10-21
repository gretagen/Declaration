-- Install prefix, overridable so a working tree can be tested without a
-- repack (NACELLE_LIB=/home/gretagen/nacelle ./nacelle spin house).
local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

package.path = LIB .. "/house-handlers/house_generators/?.lua;"
  .. LIB .. "/house-handlers/?.lua;" .. package.path

local config = require("config")

local house_sync = {}

-- verbose diagnostics: silent unless the CLI passed --verbose (which exports
-- NACELLE_VERBOSE=1). Errors never travel through vprint: generator load
-- failures and planner crashes are written straight to stderr so a normal
-- run still shows them.
local VERBOSE = os.getenv("NACELLE_VERBOSE") ~= nil

function house_sync.vprint(...)
  if not VERBOSE then return end
  io.stderr:write("[v] ")
  io.stderr:write(string.format(...))
  io.stderr:write("\n")
end

function house_sync.eprint(fmt, ...)
  io.stderr:write("[error] ")
  io.stderr:write(string.format(fmt, ...))
  io.stderr:write("\n")
end

-- file I/O helpers
function house_sync.read_file(path)
  house_sync.vprint("read_file %s", path)
  local f, err = io.open(path, "r")
  if not f then
    house_sync.vprint("  → not found")
    return nil
  end
  local c = f:read("*a")
  f:close()
  house_sync.vprint("  → %d bytes", #c)
  return c
end

function house_sync.file_exists(path)
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

function house_sync.ensure_dir(dir)
  local f = io.open(dir, "r")
  if f then f:close(); return true end
  io.stderr:write("[warn] creating directory: " .. dir .. "\n")
  return house_sync.shell("mkdir -p '" .. dir .. "'")
end

function house_sync.write_file(path, content)
  house_sync.vprint("write_file %s (%d bytes)", path, #content)
  local dir = path:match("^(.*/)")
  if dir then
    local ok = house_sync.ensure_dir(dir)
    if not ok then return false, "failed to create " .. dir end
  end
  local f, err = io.open(path, "w")
  if not f then return false, err end
  f:write(content)
  f:close()
  return true
end

-- shell helpers
function house_sync.shell(cmd)
  house_sync.vprint("shell: %s", cmd)
  local ok = os.execute(cmd .. " 2>/dev/null")
  return ok
end

function house_sync.shell_output(cmd)
  local f = io.popen(cmd .. " 2>/dev/null")
  if not f then return "" end
  local out = f:read("*a")
  f:close()
  return out:gsub("%s+$", "")
end

-- quote one argument for embedding inside /bin/bash -c "..."
function house_sync.shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- run a user command under /bin/bash with output visible
function house_sync.shell_live(cmd)
  house_sync.vprint("bash: %s", cmd)
  return os.execute("/bin/bash -c " .. house_sync.shell_quote(cmd))
end

-- silent probe under /bin/bash: true only when the command exits 0
function house_sync.shell_ok(cmd)
  return os.execute("/bin/bash -c " .. house_sync.shell_quote(cmd .. " 2>/dev/null")) == true
end

-- true when the current user can write path (or, for a missing path, its
-- nearest existing ancestor directory, since write_file/mkdir -p build
-- everything from there down). Root is assumed able to write anywhere, so
-- only unprivileged runs pay the probe cost.
function house_sync.writable_path(path)
  if not house_sync.unprivileged then return true end
  if house_sync.file_exists(path) then
    return house_sync.shell_ok("test -w " .. house_sync.shell_quote(path))
  end
  return house_sync.shell_ok(
    "d=" .. house_sync.shell_quote(path) ..
    "; while [ ! -e \"$d\" ]; do d=$(dirname -- \"$d\"); done" ..
    "; [ -d \"$d\" ] && [ -w \"$d\" ] && [ -x \"$d\" ]")
end

-- true when the current user owns path: chmod (script generator) needs
-- ownership even when the file itself is writable.
function house_sync.owns(path)
  if not house_sync.unprivileged then return true end
  return house_sync.shell_ok("test -O " .. house_sync.shell_quote(path))
end

-- change builder
function house_sync.change(type_, generator, target, detail, apply_fn)
  return {
    type = type_ or "~",
    section = generator,
    generator = generator,
    target = target,
    detail = detail,
    apply_fn = apply_fn,
  }
end

-- load house generators
local generators = {}
local generator_names = {
  "edit",
  "script",
  "media",
  "command",
}

house_sync.vprint("loading house generators...")
for _, name in ipairs(generator_names) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    house_sync.vprint("  generator '%s' loaded", name)
  else
    -- always visible: a silently dropped generator would make the run
    -- report success while planning with a smaller set than the house asks
    house_sync.eprint("house generator '%s' failed to load: %s", name, tostring(gen))
  end
end
house_sync.vprint("%d generators loaded", #generators)

-- collect all changes
function house_sync.collect(cfg)
  local changes = {}
  local seq = 0
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    house_sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, house_sync)
    if ok and plans then
      house_sync.vprint("  → %d changes", #plans)
      for _, c in ipairs(plans) do
        c.seq = seq
        seq = seq + 1
        table.insert(changes, c)
      end
    else
      -- always visible, same reason as a failed load: the plan is incomplete
      house_sync.eprint("house planner '%s' crashed: %s", name, tostring(plans))
    end
  end
  -- stable sort: order by change type, keep declaration order within a type
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    local oa, ob = order[a.type] or 0, order[b.type] or 0
    if oa ~= ob then return oa < ob end
    return (a.seq or 0) < (b.seq or 0)
  end)
  house_sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function house_sync.summary(changes)
  if #changes == 0 then
    print("The House seems to be already synchronized, no changes required.")
    return
  end
  local groups = {}
  for _, c in ipairs(changes) do
    local s = c.section or "misc"
    if not groups[s] then groups[s] = {} end
    table.insert(groups[s], c)
  end
  print()
  print("  House Synchronization plan")
  print("  " .. string.rep("=", 40))
  if house_sync.unprivileged then
    print("  mode: unprivileged (root-only changes will be skipped)")
  end
  print()
  for s, entries in pairs(groups) do
    print("  [" .. s .. "]")
    for _, c in ipairs(entries) do
      local sym = c.type == "+" and " [+] " or c.type == "-" and " [-] " or " [~] "
      local line = "    " .. sym .. c.target
      if c.requires_root then
        line = line .. "  (requires root : will be skipped)"
      end
      print(line)
      if c.detail then
        print("         " .. c.detail)
      end
    end
    print()
  end
end

-- apply all changes
function house_sync.apply(changes)
  local failures = 0
  local skipped = 0
  for _, c in ipairs(changes) do
    local sym = c.type == "+" and "[+]" or c.type == "-" and "[-]" or "[~]"
    if c.requires_root then
      io.stderr:write(string.format("[skip] %s %s/%s (requires root)\n", sym, c.section or "?", c.target))
      skipped = skipped + 1
    else
      io.stderr:write(string.format("[apply] %s %s/%s\n", sym, c.section or "?", c.target))
      if c.apply_fn then
        local ok, result = pcall(c.apply_fn, c, house_sync)
        if not ok then
          io.stderr:write("[error] " .. tostring(result) .. "\n")
          failures = failures + 1
        elseif result == false then
          io.stderr:write("[error] command failed\n")
          failures = failures + 1
        else
          io.stderr:write("[ok] " .. sym .. " " .. (c.section or "?") .. "/" .. c.target .. "\n")
        end
      end
    end
  end
  if failures > 0 then
    io.stderr:write(string.format("\n[warn] %d change(s) failed : review errors above\n", failures))
  end
  return true, failures, skipped
end

-- CLI entry point
if arg and arg[0] and arg[0]:match("house_sync%.lua$") then
  local uid = tonumber((house_sync.shell_output("id -u")))
  house_sync.unprivileged = (uid ~= 0)
  if house_sync.unprivileged then
    io.stderr:write("note: running without privileges : changes to system paths will be skipped, and no generation will be created.\n")
  end

  local cfg_path = arg[1] or "/etc/nacelle/houses/house.lua"
  house_sync.vprint("loading house config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end

  local changes = house_sync.collect(cfg)
  house_sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  -- unprivileged run where nothing can actually be applied: say so and stop
  -- before asking a pointless y/N question.
  if house_sync.unprivileged then
    local applicable = 0
    for _, c in ipairs(changes) do
      if not c.requires_root then applicable = applicable + 1 end
    end
    if applicable == 0 then
      print(#changes .. " change(s) require root : re-run with superuser privileges.")
      os.exit(0)
    end
  end

  io.write("Proceed with house synchronization? [y/N]: ")
  io.flush()
  local answer = io.read()
  local ok = answer and (answer:lower() == "y" or answer:lower() == "yes")
  if not ok then
    print("Cancelled.")
    os.exit(0)
  end

  print("Applying house changes...")
  local _, failures, skipped = house_sync.apply(changes)
  if failures and failures > 0 then
    print("House synchronization finished with " .. failures .. " failure(s).")
    io.stderr:write("No new generation created : fix errors and re-run, or boot a previous generation.\n")
  elseif house_sync.unprivileged then
    print("House synchronization completed (unprivileged : no generation created).")
    if skipped and skipped > 0 then
      print(skipped .. " change(s) were skipped : re-run with superuser privileges to apply them.")
    end
  else
    print("Creating post-sync house generation...")
    if not house_sync.shell("chronos create 'post-sync house'") then
      io.stderr:write("[warn] chronos create failed : house is synced but no new boot entry was added.\n")
      io.stderr:write("        Check btrfs layout (@ / @snapshots) and run: chronos create 'post-sync house'\n")
    end
    print("House synchronization completed.")
  end
end

return house_sync
