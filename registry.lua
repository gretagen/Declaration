-- registry.lua: saved configuration copies for nacelle.
--
--   nacelle register   {system|house} [/path/to/file.lua]   prompt for a name, save a copy
--   nacelle unregister {system|house} <name>                delete a saved copy
--   nacelle see-registered {system|house}                   list saved copies
--   nacelle load       {system|house} <name>                put a saved copy back in place
--
-- Copies live in /etc/nacelle/registered/definitions/ and
-- /etc/nacelle/registered/houses/, one <name>.lua per registration. A copy
-- is validated with the loader of its category before being saved and before
-- being loaded back, so a broken backup can never replace a working config.

local LIB = os.getenv("NACELLE_LIB")
if not LIB or LIB == "" then LIB = "/usr/lib/nacelle" end
package.path = LIB .. "/?.lua;" .. package.path

local registry = {}

-- where copies are stored, and what each category replaces when loaded
local DIRS = {
  system = "/etc/nacelle/registered/definitions",
  house  = "/etc/nacelle/registered/houses",
}

local LIVE = {
  system = "/etc/nacelle/definition.lua",
  house  = "/etc/nacelle/houses/house.lua",
}

-- "definition"/"def" name the system category the way the file does
local CATEGORY_ALIASES = {
  system = "system", definition = "system", def = "system",
  house = "house", houses = "house",
}

local function canonical_category(cat)
  if type(cat) ~= "string" then return nil end
  return CATEGORY_ALIASES[cat]
end

-- Names become a single path segment: letters, digits, '.', '_', '-',
-- starting with a letter or digit, so nothing can walk out of DIRS.
local function valid_name(name)
  return type(name) == "string" and name:match("^[%w][%w._-]*$") ~= nil
end

local function normalize_name(name)
  if type(name) ~= "string" then return nil end
  name = name:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.lua$", "")
  if name == "" then return nil end
  return name
end

local function q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function write_file(path, content)
  local dir = path:match("^(.*/)")
  if dir then os.execute("mkdir -p " .. q(dir)) end
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  return true
end

local function file_date(path)
  local p = io.popen("stat -c %Y " .. q(path) .. " 2>/dev/null")
  if not p then return "unknown" end
  local out = p:read("*a")
  p:close()
  local t = tonumber((out or ""):match("%d+"))
  if not t then return "unknown" end
  return os.date("%Y-%m-%d", t)
end

local function fail(fmt, ...)
  io.stderr:write("error: " .. string.format(fmt, ...) .. "\n")
  os.exit(1)
end

local function confirm(prompt)
  io.write(prompt)
  io.flush()
  local answer = io.read()
  if not answer then return false end
  answer = answer:lower()
  return answer == "y" or answer == "yes"
end

-- Validate a config file for its category using that category's own loader.
-- The house loader is loaded with loadfile so it cannot collide with the
-- system config module, both of which are called config.lua.
local function validate(cat, path)
  if not read_file(path) then
    return nil, "cannot read " .. path
  end
  if cat == "system" then
    local ok, err = require("config").load(path)
    if not ok then return nil, err end
    return true
  end

  local chunk, cerr = loadfile(LIB .. "/house-handlers/config.lua")
  if not chunk then
    return nil, "house config loader unavailable: " .. tostring(cerr)
  end
  local called, mod = pcall(chunk)
  if not called or type(mod) ~= "table" or type(mod.load) ~= "function" then
    return nil, "house config loader is broken"
  end
  local ok, err = mod.load(path)
  if not ok then return nil, err end
  return true
end

-- Saved copies for a category, sorted by name.
local function registered_names(cat)
  local p = io.popen("ls -1 " .. q(DIRS[cat]) .. " 2>/dev/null")
  if not p then return {} end
  local names = {}
  for line in p:lines() do
    local name = line:match("^(.+)%.lua$")
    if name then names[#names + 1] = name end
  end
  p:close()
  table.sort(names)
  return names
end

function registry.register(cat, src)
  src = src or LIVE[cat]
  if not read_file(src) then
    fail("cannot read %s", src)
  end
  local ok, err = validate(cat, src)
  if not ok then
    fail("refusing to register an invalid %s config (%s):\n%s", cat, src, tostring(err))
  end

  io.write("name of the config to register : ")
  io.flush()
  local name = normalize_name(io.read())
  if not name then fail("no name given") end
  if not valid_name(name) then
    fail("invalid name '%s': use letters, digits, '.', '_', '-', starting with a letter or digit", name)
  end

  local dest = DIRS[cat] .. "/" .. name .. ".lua"
  if read_file(dest) then
    if not confirm("'" .. name .. "' is already registered, overwrite? [y/N]: ") then
      print("Cancelled.")
      os.exit(0)
    end
  end

  local w, werr = write_file(dest, read_file(src))
  if not w then fail("cannot write %s: %s", dest, tostring(werr)) end
  print("Registered '" .. name .. "' (" .. cat .. ") from " .. src)
end

function registry.unregister(cat, name)
  name = normalize_name(name)
  if not name then
    fail("usage: nacelle unregister {system|house} <name>")
  end
  if not valid_name(name) then
    fail("invalid name '%s'", name)
  end
  local path = DIRS[cat] .. "/" .. name .. ".lua"
  if not read_file(path) then
    fail("'%s' is not a registered %s config", name, cat)
  end
  if not confirm("delete '" .. name .. "' (" .. cat .. ")? [y/N]: ") then
    print("Cancelled.")
    os.exit(0)
  end
  os.remove(path)
  print("Unregistered '" .. name .. "' (" .. cat .. ")")
end

function registry.list(cat)
  local names = registered_names(cat)
  if #names == 0 then
    print("No " .. cat .. " config registered.")
    return
  end
  print()
  for i, name in ipairs(names) do
    print(string.format("%3d  %-20s %s", i, name, file_date(DIRS[cat] .. "/" .. name .. ".lua")))
  end
  print()
end

function registry.load(cat, name)
  name = normalize_name(name)
  if not name then
    fail("usage: nacelle load {system|house} <name>")
  end
  if not valid_name(name) then
    fail("invalid name '%s'", name)
  end
  local src = DIRS[cat] .. "/" .. name .. ".lua"
  if not read_file(src) then
    fail("'%s' is not a registered %s config", name, cat)
  end

  local ok, err = validate(cat, src)
  if not ok then
    fail("refusing to load '%s' (%s):\n%s", name, cat, tostring(err))
  end

  local w, werr = write_file(LIVE[cat], read_file(src))
  if not w then fail("cannot write %s: %s", LIVE[cat], tostring(werr)) end
  print("Loaded '" .. name .. "' into " .. LIVE[cat])
  print("Run nacelle spin " .. cat .. " to apply it.")
end

-- CLI entry point: reached only when nacelle execs this file directly
if arg and arg[0] and arg[0]:match("registry%.lua$") then
  local action = arg[1]
  local cat_raw = arg[2]
  local cat = canonical_category(cat_raw)

  local extra = {
    register   = " [/path/to/file.lua]",
    unregister = " <name>",
    load       = " <name>",
    ["see-registered"] = "",
  }
  if not cat then
    local tail = extra[action or ""] or ""
    if not cat_raw then
      fail("'%s' needs a category: nacelle %s {system|house}%s", action or "?", action or "?", tail)
    end
    fail("unknown category '%s' (expected system or house)", cat_raw)
  end

  if action == "register" then
    registry.register(cat, arg[3])
  elseif action == "unregister" then
    registry.unregister(cat, arg[3])
  elseif action == "load" then
    registry.load(cat, arg[3])
  elseif action == "see-registered" then
    registry.list(cat)
  else
    fail("unknown registry action '%s'", tostring(action))
  end
end

return registry
