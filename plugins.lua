-- plugins.lua — resolve which generators haliade-synchronize enables.
--
-- The enable list lives in /etc/nacelle/enabled_modules.lua (user-edited,
-- never owned by a package, so a declaration update can never clobber it).
-- sync.lua owns no list of its own anymore: it just asks this module
-- "who's enabled?" and iterates whatever comes back.
--
--   file missing → built-in default list (fresh installs, package tests)
--   file present → replaces the default entirely: add a generator name to
--                  enable it, remove one to disable it
--   file broken  → hard error naming the file (never sync with a half-read
--                  list)
--
-- Every generator is in the same position: the defaults are only the list a
-- missing file falls back to, so anything in them (hostname included) can be
-- disabled once the file exists. nacelle enable-generator/disable-generator
-- edit the file; this module stays the one place that reads it.
--
-- Order in the return list is respected by the loader (collection is stable),
-- so the file can also order generators where that matters — subspaces must
-- run before subspaces_packages/merged_packages.

local plugins = {}

local DEFAULT_ENABLED_FILE = "/etc/nacelle/enabled_modules.lua"

-- Built-in default, used when the enable file does not exist. Keep in sync
-- with the file shipped in the rootfs (etc/haliade/enabled_modules.lua).
local DEFAULT_GENERATORS = {
  "hostname", "timezone", "locale", "hwclock", "keymap",
  "console_font", "env", "boot", "init", "packages", "packages-isolated",
  "subspaces", "subspaces_packages", "merged_packages",
  "users", "network", "fstab",
  "rc-services", "runit-services", "dinit-services", "sysmd-services",
  "modules",
  "ssh", "edit",
}

-- Load the enable file. Accepts both forms:
--   local enabled_generators = { ... }          (no return — see rootfs sketch)
--   return { ... }                              (already-returning file)
-- A missing file yields nil; the caller falls back to DEFAULT_GENERATORS.
-- Any other failure (syntax error, runtime error, wrong shape) is a hard
-- error that names the file, so a corrupt enable list can never silently
-- produce a partial sync.
--
-- Compilation order matters for correctness, not just speed: the appended
-- return is tried first so a `local enabled_generators` file is read back
-- from its own scope. A file that already ends in a top-level return makes
-- that a syntax error ("return" must be the last statement), so it falls
-- back to running the file as-is. Either form therefore executes exactly
-- once; the old order ran the local form twice and fired its side effects
-- twice.
local function load_enabled_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()

  local chunk, err = load(src .. "\nreturn enabled_generators", "@" .. path .. " (+return)")
  if not chunk then
    chunk, err = load(src, "@" .. path)
  end
  if not chunk then
    error("plugin enable file " .. path .. ": " .. tostring(err), 0)
  end

  local ok, res = pcall(chunk)
  if not ok then
    error("plugin enable file " .. path .. ":\n" .. tostring(res), 0)
  end
  if type(res) ~= "table" then
    error("plugin enable file " .. path ..
      " must define local enabled_generators = { ... } or return the list, got "
      .. type(res), 0)
  end
  return res
end

-- A fresh copy of the built-in list, so callers can reshape it without
-- touching DEFAULT_GENERATORS.
function plugins.defaults()
  local out = {}
  for _, name in ipairs(DEFAULT_GENERATORS) do
    out[#out + 1] = name
  end
  return out
end

-- Same as enabled_generators, but also reports where the list came from:
-- the second return is the enable file path, or nil when the built-in
-- default list is in use (fresh installs, package tests).
function plugins.enabled_source(path)
  local p = path or DEFAULT_ENABLED_FILE
  local list = load_enabled_file(p)
  if list == nil then
    return plugins.defaults(), nil
  end
  return list, p
end

-- Return the list of enabled generators for a sync run. The optional argument
-- overrides the default file location (used by package tests).
function plugins.enabled_generators(path)
  local list = load_enabled_file(path or DEFAULT_ENABLED_FILE)
  if list == nil then
    return plugins.defaults()
  end
  return list
end

-- CLI entry point, reached only when nacelle execs this file directly:
--   lua plugins.lua see-enabled
--   lua plugins.lua enable-generator  <name>
--   lua plugins.lua disable-generator <name>
if arg and arg[0] and arg[0]:match("plugins%.lua$") then
  local LIB = os.getenv("NACELLE_LIB")
  if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

  local function fail(fmt, ...)
    io.stderr:write("error: " .. string.format(fmt, ...) .. "\n")
    os.exit(1)
  end

  local function resolves(name)
    local f = io.open(LIB .. "/generators/" .. name .. ".lua", "r")
    if f then f:close() return true end
    return false
  end

  local function valid_name(name)
    return type(name) == "string" and name:match("^[%w][%w._-]*$") ~= nil
  end

  -- The enable file's order is the run order, so warn when an edit strands a
  -- name that has to run after another one.
  local function warn_order(list)
    local pos = {}
    for i, n in ipairs(list) do pos[n] = i end
    local checks = {
      { "subspaces", "subspaces_packages" },
      { "subspaces", "merged_packages" },
    }
    for _, c in ipairs(checks) do
      local first, later = c[1], c[2]
      if pos[first] and pos[later] and pos[first] > pos[later] then
        io.stderr:write("[warn] order: '" .. first .. "' runs after '" .. later
          .. "' in " .. DEFAULT_ENABLED_FILE .. " : move it up ("
          .. first .. " must run first)\n")
      end
    end
  end

  -- Rewrite the enable file in canonical form. One .bak copy of whatever is
  -- there now is kept alongside, so a bad edit is never the only copy.
  local function write_enabled(list)
    local lines = {
      "-- Generators a sync runs. Add a name to enable it, remove one to disable it.",
      "-- Order is respected: subspaces must run before subspaces_packages and",
      "-- merged_packages.",
      "local enabled_generators = {",
    }
    for _, name in ipairs(list) do
      lines[#lines + 1] = '  "' .. name .. '",'
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "return enabled_generators"
    local content = table.concat(lines, "\n") .. "\n"

    local old = io.open(DEFAULT_ENABLED_FILE, "r")
    if old then
      local prev = old:read("*a")
      old:close()
      local bak = io.open(DEFAULT_ENABLED_FILE .. ".bak", "w")
      if bak then
        bak:write(prev)
        bak:close()
      end
    end

    local out, err = io.open(DEFAULT_ENABLED_FILE, "w")
    if not out then
      fail("cannot write %s: %s", DEFAULT_ENABLED_FILE, tostring(err))
    end
    out:write(content)
    out:close()
  end

  local function ctl(action, raw)
    local name = raw
    if type(name) == "string" then
      name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.lua$", "")
    end
    if not name or name == "" then
      fail("usage: nacelle %s <generator name>", action)
    end
    if not valid_name(name) then
      fail("invalid generator name '%s': use letters, digits, '.', '_', '-', "
        .. "starting with a letter or digit", name)
    end

    local list = plugins.enabled_source()

    if action == "enable-generator" then
      for _, n in ipairs(list) do
        if n == name then
          print("'" .. name .. "' is already enabled.")
          os.exit(0)
        end
      end
      if not resolves(name) then
        io.stderr:write("[warn] nothing provides '" .. name .. "' yet : it will "
          .. "show as MISSING until the package shipping it is installed\n")
      end
      list[#list + 1] = name
      warn_order(list)
      write_enabled(list)
      print("Enabled '" .. name .. "' (" .. #list .. " generators).")
    else
      local idx
      for i, n in ipairs(list) do
        if n == name then
          idx = i
          break
        end
      end
      if not idx then
        fail("'%s' is not enabled", name)
      end
      table.remove(list, idx)
      warn_order(list)
      write_enabled(list)
      print("Disabled '" .. name .. "' (" .. #list .. " generators).")
    end
  end

  local function print_enabled()
    local list, src = plugins.enabled_source()
    if src then
      print("enabled generators : " .. src .. " (" .. #list .. ")")
    else
      print("enabled generators : built-in default list (" .. #list .. ")")
    end
    print()

    local on = {}
    local missing = 0
    for i, name in ipairs(list) do
      on[name] = true
      local status = resolves(name) and "enabled" or "MISSING"
      if status == "MISSING" then missing = missing + 1 end
      print(string.format("%3d  %-24s %s", i, tostring(name), status))
    end

    -- Everything known but not enabled: default names dropped from the list,
    -- plus generator files on disk nobody enabled (typically a plugin package
    -- that ships its generator but leaves the choice to this list).
    local off = {}
    for _, name in ipairs(DEFAULT_GENERATORS) do
      if not on[name] then off[name] = true end
    end
    local p = io.popen("ls -1 '" .. LIB .. "/generators' 2>/dev/null")
    if p then
      for line in p:lines() do
        local name = line:match("^(.+)%.lua$")
        if name and not on[name] then off[name] = true end
      end
      p:close()
    end

    local names = {}
    for name in pairs(off) do names[#names + 1] = name end
    table.sort(names)
    if #names > 0 then
      print()
      print("not enabled:")
      print("  " .. table.concat(names, "  "))
    end

    if missing > 0 then
      print()
      print(missing .. " generator(s) are enabled but no file provides them.")
      print("Install the package shipping them, or remove the name from the enable file.")
      os.exit(1)
    end
    os.exit(0)
  end

  local action = arg[1]
  if action == "see-enabled" then
    print_enabled()
  elseif action == "enable-generator" or action == "disable-generator" then
    ctl(action, arg[2])
  else
    fail("unknown plugins action '%s' (expected see-enabled, "
      .. "enable-generator or disable-generator)", tostring(action))
  end
end

return plugins
