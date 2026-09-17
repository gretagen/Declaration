package.path = "/usr/lib/declaration/?.lua;/usr/lib/declaration/generators/?.lua;" .. package.path

local config = require("config")

local sync = {}

-- verbose output
function sync.vprint(...)
  io.stderr:write("[v] ")
  io.stderr:write(string.format(...))
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
local generators = {}
local generator_names = {
  "hostname", "t1imezone", "locale", "hwclock", "keymap",
  "console_font", "env", "boot", "init", "packages",
  "subspaces", "users", "network", "fstab", "services", "modules",
  "ssh", "edit",
}

sync.vprint("loading generators...")
for _, name in ipairs(generator_names) do
  local ok, gen = pcall(require, name)
  if ok and type(gen) == "table" then
    table.insert(generators, gen)
    sync.vprint("  generator '%s' loaded", name)
  else
    sync.vprint("  generator '%s' FAILED: %s", name, tostring(gen))
  end
end
sync.vprint("%d generators loaded", #generators)

-- collect all changes
function sync.collect(cfg)
  local changes = {}
  for _, gen in ipairs(generators) do
    local name = gen.name or "?"
    sync.vprint("planner '%s' running...", name)
    local ok, plans = pcall(gen.plan, cfg, sync)
    if ok and plans then
      sync.vprint("  → %d changes", #plans)
      for _, c in ipairs(plans) do
        table.insert(changes, c)
      end
    else
      sync.vprint("  → ERROR: %s", tostring(plans))
    end
  end
  table.sort(changes, function(a, b)
    local order = { ["+"] = 1, ["~"] = 2, ["-"] = 3 }
    return (order[a.type] or 0) < (order[b.type] or 0)
  end)
  sync.vprint("total changes: %d", #changes)
  return changes
end

-- print summary
function sync.summary(changes)
  if #changes == 0 then
    print("System is already synchronized — no changes required.")
    return
  end
  local groups = {}
  for _, c in ipairs(changes) do
    local s = c.section or "misc"
    if not groups[s] then groups[s] = {} end
    table.insert(groups[s], c)
  end
  print()
  print("  Haliade Synchronize — Plan")
  print("  " .. string.rep("=", 40))
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
      end
    end
  end
  if failures > 0 then
    io.stderr:write(string.format("\n[warn] %d change(s) failed — review errors above\n", failures))
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

  local cfg_path = arg[1] or "/etc/haliade/definition.lua"
  sync.vprint("loading config from %s", cfg_path)
  local cfg, err = config.load(cfg_path)
  if not cfg then
    io.stderr:write("error: " .. err .. "\n")
    os.exit(1)
  end
  sync.vprint("config loaded: hostname=%s, timezone=%s, packages=%d, services=%d",
    cfg.hostname, cfg.timezone, #cfg.packages, #cfg.services)

  local changes = sync.collect(cfg)
  sync.summary(changes)

  if #changes == 0 then os.exit(0) end

  io.write("Proceed with synchronization? [y/N]: ")
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
    io.stderr:write("No new generation created — fix errors and re-run, or boot a previous generation.\n")
  else
    print("Creating post-sync generation...")
    if not sync.shell("genzee create 'post-sync'") then
      io.stderr:write("[warn] genzee create failed — system is synced but no new boot entry was added.\n")
      io.stderr:write("        Check btrfs layout (@ / @snapshots) and run: genzee create 'post-sync'\n")
    end
    print("Synchronization complete.")
  end
end



return sync
