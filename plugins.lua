-- plugins.lua — resolve which generators haliade-synchronize enables.
--
-- Which generators run is decided by an enable list per category:
--
--   system → /etc/nacelle/enabled_system_generators.lua
--            variable: local enabled_system_generators = { ... }
--   house  → /etc/nacelle/houses/enabled_house_generators.lua
--            variable: local enabled_house_generators = { ... }
--
-- Each category owns its own file *and* its own variable name, so the two
-- lists stay separated and each file reads back under its own name. Older
-- spellings are still read (legacy_files below, and the generic
-- `enabled_generators` variable), because a file that exists under an old
-- name and is silently ignored would make the sync fall back to the built-in
-- defaults — which means uninstalling packages nobody asked to remove.
--
-- Both files are user-edited, never owned by a package, so a declaration
-- update can never clobber them. sync.lua and house_sync.lua own no list of
-- their own anymore: they just ask this module "who's enabled?" and iterate
-- whatever comes back.
--
--   file missing → the category's built-in default list (fresh installs,
--                  package tests)
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
-- Categories are exact words: system or house, no aliases (registry.lua has
-- its own alias table for register/load; this one does not borrow it).
--
-- Order in the return list is respected by the loader (collection is stable),
-- so a file can also order generators where that matters — on the system
-- side subspaces must run before subspaces_packages/merged_packages.

local plugins = {}

-- Install prefix, hoisted to module level because each category's
-- generators_dir is resolved against it (NACELLE_LIB points the CLI at
-- another tree, so a working copy can be tested without repacking).
local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end

local CATEGORIES = {
  system = {
    enabled_file   = "/etc/nacelle/enabled_system_generators.lua",
    list_var       = "enabled_system_generators",
    -- Older names still read when the current one is absent (see
    -- enabled_source). Keep the rootfs copy in step with the current name:
    -- etc/haliade/enabled_system_generators.lua.
    legacy_files   = { "/etc/nacelle/enabled_modules.lua" },
    generators_dir = LIB .. "/generators",
    -- Built-in default, used when no enable file exists at all.
    defaults = {
      "hostname", "timezone", "locale", "hwclock", "keymap",
      "console_font", "env", "boot", "init", "packages", "packages-isolated",
      "subspaces", "subspaces_packages", "merged_packages",
      "users", "network", "fstab",
      "rc-services", "runit-services", "dinit-services", "sysmd-services",
      "modules",
      "ssh", "edit",
    },
    -- Name pairs that must stay in this order in the enable file.
    order_checks = {
      { "subspaces", "subspaces_packages" },
      { "subspaces", "merged_packages" },
    },
  },

  house = {
    enabled_file   = "/etc/nacelle/houses/enabled_house_generators.lua",
    list_var       = "enabled_house_generators",
    legacy_files   = { "/etc/nacelle/houses/enabled_house_modules.lua" },
    generators_dir = LIB .. "/house-handlers/house_generators",
    -- Built-in default, used when no enable file exists at all; keep in sync
    -- with the file shipped in the rootfs
    -- (etc/haliade/enabled_house_generators.lua); house_sync.lua no longer
    -- carries a list of its own.
    defaults = { "edit", "script", "media", "command" },
    order_checks = {},
  },
}

local function canonical_category(cat)
  if type(cat) ~= "string" then return nil end
  if CATEGORIES[cat] then return cat end
  return nil
end

-- What callers hand to enabled_generators/enabled_source:
--   nil              → the system category (compat with the pre-category
--                      signature, used by sync.lua and package tests)
--   "system"/"house" → that category and its enable file
--   a path           → an explicit file ("/..." or "*.lua"), for tests that
--                      point at their own enable list
-- Anything else is an error naming the two valid categories.
local function resolve_ref(ref)
  if ref == nil then return "system" end
  local cat = canonical_category(ref)
  if cat then return cat end
  if type(ref) == "string" and (ref:find("/", 1, true) or ref:match("%.lua$")) then
    return nil, ref
  end
  error("unknown category '" .. tostring(ref) .. "' (expected system or house)", 0)
end

-- Load the enable file at `path`. The list should live in `list_var` (the
-- category's own variable name). Accepted forms:
--   local <list_var> = { ... }             (canonical, no return needed)
--   local enabled_generators = { ... }     (pre-rename file, hand copies)
--   return { ... }                         (already-returning file)
-- A missing file yields nil; the caller falls back to the category's legacy
-- names, then to its built-in defaults. Any other failure (syntax error,
-- runtime error, wrong shape) is a hard error that names the file, so a
-- corrupt enable list can never silently produce a partial sync.
--
-- Compilation order matters for correctness, not just speed: the appended
-- returns are tried before running the file as-is, so a `local <list_var>`
-- file is read back from its own scope. A file that already ends in a
-- top-level return makes every appended form a syntax error ("return" must
-- be the last statement), so it falls back to running the file as-is — and
-- each file therefore runs at most once per form that compiles, never twice
-- in the same attempt.
local function load_enabled_file(path, list_var)
  list_var = list_var or "enabled_generators"
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()

  local attempts = {
    { src .. "\nreturn " .. list_var, " (+return " .. list_var .. ")" },
  }
  if list_var ~= "enabled_generators" then
    attempts[#attempts + 1] =
      { src .. "\nreturn enabled_generators", " (+return enabled_generators)" }
  end
  attempts[#attempts + 1] = { src, "" }

  local syntax_err, got_type
  for _, a in ipairs(attempts) do
    local chunk, cerr = load(a[1], "@" .. path .. a[2])
    if not chunk then
      syntax_err = cerr
    else
      syntax_err = nil
      local ok, res = pcall(chunk)
      if not ok then
        error("plugin enable file " .. path .. ":\n" .. tostring(res), 0)
      end
      if type(res) == "table" then return res end
      got_type = type(res)
    end
  end

  if syntax_err then
    error("plugin enable file " .. path .. ": " .. tostring(syntax_err), 0)
  end
  error("plugin enable file " .. path ..
    " must define local " .. list_var .. " = { ... } or return the list, got "
    .. tostring(got_type), 0)
end

-- A fresh copy of a category's built-in list, so callers can reshape it
-- without touching CATEGORIES. Defaults to the system category.
function plugins.defaults(category)
  local cat = canonical_category(category or "system")
  if not cat then
    error("unknown category '" .. tostring(category) .. "' (expected system or house)", 0)
  end
  local out = {}
  for _, name in ipairs(CATEGORIES[cat].defaults) do
    out[#out + 1] = name
  end
  return out
end

-- A name listed twice would run its planner twice (every change planned
-- twice), so the first occurrence wins — and the file it came from says so.
local function dedupe(list, path)
  local seen, out, dups = {}, {}, {}
  for _, name in ipairs(list) do
    if seen[name] then
      dups[#dups + 1] = name
    else
      seen[name] = true
      out[#out + 1] = name
    end
  end
  if #dups > 0 then
    io.stderr:write("[warn] " .. path .. " lists " .. #dups
      .. " duplicate generator(s) ('" .. table.concat(dups, "', '")
      .. "') : only the first occurrence runs\n")
  end
  return out
end

-- Same as enabled_generators, but also reports where the list came from:
-- the second return is the file that was actually read (current name or a
-- legacy one), or nil when the category's built-in default list is in use
-- (fresh installs, package tests).
function plugins.enabled_source(ref)
  local cat, path = resolve_ref(ref)
  if path then
    -- explicit file (package tests): the generic variable name is the only
    -- thing assumed about it
    local list = load_enabled_file(path, "enabled_generators")
    if list == nil then return plugins.defaults("system"), nil end
    return dedupe(list, path), path
  end

  local cfg = CATEGORIES[cat]
  local list = load_enabled_file(cfg.enabled_file, cfg.list_var)
  if list then return dedupe(list, cfg.enabled_file), cfg.enabled_file end

  -- Current name absent: an older spelling of the same file still counts,
  -- and it is announced — a file silently ignored here would make the sync
  -- fall back to the built-in defaults and start removing packages.
  for _, legacy in ipairs(cfg.legacy_files) do
    local l = load_enabled_file(legacy, cfg.list_var)
    if l then
      io.stderr:write("[note] reading legacy enable file " .. legacy
        .. " : rename it to " .. cfg.enabled_file .. "\n")
      return dedupe(l, legacy), legacy
    end
  end

  return plugins.defaults(cat), nil
end

-- Return the list of enabled generators for a sync run. The optional
-- argument is a category ("system", "house") or an explicit enable file
-- path (used by package tests); nil means the system category.
function plugins.enabled_generators(ref)
  local list = plugins.enabled_source(ref)
  return list
end

-- CLI entry point, reached only when nacelle execs this file directly:
--   lua plugins.lua see-enabled           <category>
--   lua plugins.lua enable-generator      <category> <name>
--   lua plugins.lua disable-generator     <category> <name>
if arg and arg[0] and arg[0]:match("plugins%.lua$") then

  local function fail(fmt, ...)
    io.stderr:write("error: " .. string.format(fmt, ...) .. "\n")
    os.exit(1)
  end

  local function resolves(cat, name)
    local f = io.open(CATEGORIES[cat].generators_dir .. "/" .. name .. ".lua", "r")
    if f then f:close() return true end
    return false
  end

  local function valid_name(name)
    return type(name) == "string" and name:match("^[%w][%w._-]*$") ~= nil
  end

  -- A category's order_checks describe names that must stay in this order
  -- in its enable file, so warn when an edit strands one after the other.
  local function warn_order(cat, list)
    local checks = CATEGORIES[cat].order_checks
    if #checks == 0 then return end
    local pos = {}
    for i, n in ipairs(list) do pos[n] = i end
    for _, c in ipairs(checks) do
      local first, later = c[1], c[2]
      if pos[first] and pos[later] and pos[first] > pos[later] then
        io.stderr:write("[warn] order: '" .. first .. "' runs after '" .. later
          .. "' in " .. CATEGORIES[cat].enabled_file .. " : move it up ("
          .. first .. " must run first)\n")
      end
    end
  end

  -- Rewrite the category's enable file in canonical form (its own variable
  -- name, its own path). One .bak copy of whatever is there now is kept
  -- alongside, so a bad edit is never the only copy. When the current name
  -- did not exist yet, the list just written came from a legacy path, which
  -- is removed so only one file is ever read.
  local function write_enabled(cat, list)
    local cfg = CATEGORIES[cat]
    local lines = {
      "-- Generators a " .. cat .. " sync runs. Add a name to enable it, remove one to disable it.",
    }
    if #cfg.order_checks > 0 then
      lines[#lines + 1] = "-- Order is respected: subspaces must run before subspaces_packages and"
      lines[#lines + 1] = "-- merged_packages."
    end
    lines[#lines + 1] = "local " .. cfg.list_var .. " = {"
    for _, name in ipairs(list) do
      lines[#lines + 1] = '  "' .. name .. '",'
    end
    lines[#lines + 1] = "}"
    lines[#lines + 1] = "return " .. cfg.list_var
    local content = table.concat(lines, "\n") .. "\n"

    local had_current = io.open(cfg.enabled_file, "r")
    if had_current then
      local prev = had_current:read("*a")
      had_current:close()
      local bak = io.open(cfg.enabled_file .. ".bak", "w")
      if bak then
        bak:write(prev)
        bak:close()
      end
    end

    local dir = cfg.enabled_file:match("^(.*/)")
    if dir then os.execute("mkdir -p '" .. dir .. "'") end
    local out, err = io.open(cfg.enabled_file, "w")
    if not out then
      fail("cannot write %s: %s", cfg.enabled_file, tostring(err))
    end
    out:write(content)
    out:close()

    if not had_current then
      for _, legacy in ipairs(cfg.legacy_files) do
        local lf = io.open(legacy, "r")
        if lf then
          lf:close()
          if os.remove(legacy) then
            print("Migrated " .. legacy .. " to " .. cfg.enabled_file .. ".")
          else
            io.stderr:write("[warn] could not remove legacy " .. legacy
              .. " : " .. cfg.enabled_file .. " now wins, remove it by hand\n")
          end
        end
      end
    end
  end

  local function ctl(action, cat, raw)
    local name = raw
    if type(name) == "string" then
      name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.lua$", "")
    end
    if not name or name == "" then
      fail("usage: nacelle %s {system|house} <generator name>", action)
    end
    if not valid_name(name) then
      fail("invalid generator name '%s': use letters, digits, '.', '_', '-', "
        .. "starting with a letter or digit", name)
    end

    local list = plugins.enabled_source(cat)

    if action == "enable-generator" then
      for _, n in ipairs(list) do
        if n == name then
          print("'" .. name .. "' is already enabled.")
          os.exit(0)
        end
      end
      if not resolves(cat, name) then
        io.stderr:write("[warn] nothing provides '" .. name .. "' yet : it will "
          .. "show as MISSING until the package shipping it is installed\n")
      end
      list[#list + 1] = name
      warn_order(cat, list)
      write_enabled(cat, list)
      print("Enabled '" .. name .. "' (" .. #list .. " " .. cat .. " generators).")
    else
      local idx
      for i, n in ipairs(list) do
        if n == name then
          idx = i
          break
        end
      end
      if not idx then
        fail("'%s' is not an enabled %s generator", name, cat)
      end
      table.remove(list, idx)
      warn_order(cat, list)
      write_enabled(cat, list)
      print("Disabled '" .. name .. "' (" .. #list .. " " .. cat .. " generators).")
    end
  end

  local function print_enabled(cat)
    local cfg = CATEGORIES[cat]
    local list, src = plugins.enabled_source(cat)
    if src then
      print("enabled generators (" .. cat .. ") : " .. src .. " (" .. #list .. ")")
    else
      print("enabled generators (" .. cat .. ") : built-in default list (" .. #list .. ")")
    end
    print()

    local on = {}
    local missing = 0
    for i, name in ipairs(list) do
      on[name] = true
      local status = resolves(cat, name) and "enabled" or "MISSING"
      if status == "MISSING" then missing = missing + 1 end
      print(string.format("%3d  %-24s %s", i, tostring(name), status))
    end

    -- Everything known but not enabled: default names dropped from the list,
    -- plus generator files on disk nobody enabled (typically a plugin package
    -- that ships its generator but leaves the choice to this list).
    local off = {}
    for _, name in ipairs(cfg.defaults) do
      if not on[name] then off[name] = true end
    end
    local p = io.popen("ls -1 '" .. cfg.generators_dir .. "' 2>/dev/null")
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
  if action ~= "see-enabled" and action ~= "enable-generator"
    and action ~= "disable-generator" then
    fail("unknown plugins action '%s' (expected see-enabled, "
      .. "enable-generator or disable-generator)", tostring(action))
  end

  -- Every action is category-first; the words are exact (system, house).
  local cat = canonical_category(arg[2])
  if not cat then
    if not arg[2] then
      fail("%s needs a category: nacelle %s {system|house}%s", action, action,
        action == "see-enabled" and "" or " <generator name>")
    end
    if action == "see-enabled" then
      fail("unknown category '%s' (expected system or house)", arg[2])
    end
    fail("unknown category '%s' (expected system or house)\n"
      .. "usage: nacelle %s {system|house} <generator name>", arg[2], action)
  end

  if action == "see-enabled" then
    print_enabled(cat)
  else
    ctl(action, cat, arg[3])
  end
end

return plugins
