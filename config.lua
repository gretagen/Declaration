local config = {}

local base_defaults = {
  hostname        = "haliade",
  timezone        = "UTC",
  locale          = "en_US.UTF-8",
  hwclock         = "UTC",
  keymap          = "us",
  console_font    = "latarcyrheb-sun16",
  root_partuuid   = "PLACEHOLDER",
  kernel_cmdline  = "",
  environment     = {},

  boot = {
    timeout      = 15,
    wallpaper    = "boot():/boot/image.png",
    serial       = true,
    serial_speed = 115200,
  },

  ["packages-haliade"]  = {},
  ["packages-isolated"] = {},
  subspaces = {},
  modules   = {},
  init      = "openrc",

  ["rc-services"]    = {},
  ["runit-services"] = {},
  ["dinit-services"] = {},

  users    = {},

  network = { connections = {} },
  fstab   = { extra_mounts = {} },

  ssh = {
    enable            = false,
    permit_root_login = false,
    port              = 22,
    authorized_keys   = {},
  },

  edit = {},
}

local base_schema = {
  hostname = "string", timezone = "string", locale = "string",
  hwclock = "string", keymap = "string", console_font = "string",
  root_partuuid = "string", kernel_cmdline = "string",
  environment = "table",
  boot = "table", init = "string",
  ["packages-haliade"] = "table", ["packages-isolated"] = "table",
  subspaces = "table", modules = "table", users = "table",
  ["rc-services"] = "table", ["runit-services"] = "table", ["dinit-services"] = "table",
  network = "table", fstab = "table",
  ssh = "table", edit = "table",
}

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deep_copy(v) end
  return r
end

local function merge(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" and type(dst[k]) == "table" and not v[1] then
      merge(dst[k], v)
    elseif v ~= nil then
      dst[k] = v
    end
  end
  return dst
end

-- Plugin config dir: any *.lua here runs during config.load with the working
-- `defaults` and `schema` tables in scope, so a plugin can contribute its own
-- section defaults + type validation without anyone editing config.lua.
local PLUGIN_CONFIG_DIR = "/etc/haliade/plugin-configs"

-- Execute every *.lua file in a plugin config dir with the working defaults/
-- schema tables exposed. Each file runs in an env whose globals fall through
-- to the real _G, so files are plain Lua:
--
--   defaults["nixpkgs"] = {}
--   schema["nixpkgs"]   = "table"
--
-- Later files win on key collisions. Files may add new keys but may NOT
-- replace or nil out any key declared by core (base_defaults/base_schema) —
-- that keeps a plugin from silently clobbering the built-in schema.
-- Missing dir → no-op. Broken file → hard error naming it.
local function apply_plugin_configs(dir, defaults, schema)
  if not dir or dir == "" then return true end
  local p = io.popen("ls -1 " .. dir .. " 2>/dev/null")
  if not p then return true end
  local names = {}
  for line in p:lines() do
    if line:match("^[%w_%-]+%.lua$") then
      names[#names + 1] = line
    end
  end
  p:close()

  table.sort(names)

  for _, name in ipairs(names) do
    local file = dir .. "/" .. name
    local f, rerr = io.open(file, "r")
    if not f then
      return nil, "plugin config " .. file .. ": cannot read: " .. (rerr or "unknown error")
    end
    local src = f:read("*a")
    f:close()

    -- Snapshot references before the file runs so any core-key tampering
    -- (replace, remove) is detectable afterwards.
    local before, sbefore = {}, {}
    for k, v in pairs(defaults) do before[k] = v end
    for k, v in pairs(schema) do sbefore[k] = v end

    local env = { defaults = defaults, schema = schema }
    setmetatable(env, { __index = _G })
    local fn, ferr = load(src, "@" .. file, "t", env)
    if not fn then
      return nil, "plugin config " .. file .. ": " .. (ferr or "syntax error")
    end
    local ok, perr = pcall(fn)
    if not ok then
      return nil, "plugin config " .. file .. ":\n" .. tostring(perr)
    end

    for k in pairs(base_defaults) do
      if defaults[k] ~= before[k] then
        return nil, "plugin config " .. file .. " may not override core key '" .. k .. "'"
      end
    end
    for k in pairs(base_schema) do
      if schema[k] ~= sbefore[k] then
        return nil, "plugin config " .. file .. " may not override core key '" .. k .. "'"
      end
    end
  end
  return true
end

function config.load(path, plugin_dir)
  path = path or "/etc/haliade/definition.lua"
  local f, err = io.open(path, "r")
  if not f then
    return nil, "cannot open " .. path .. ": " .. (err or "unknown error")
  end
  local code = f:read("*a")
  f:close()

  local fn, err = load(code, "@" .. path)
  if not fn then
    return nil, "syntax error in " .. path .. ":\n" .. (err or "unknown")
  end

  local ok, user = pcall(fn)
  if not ok then
    return nil, "runtime error in " .. path .. ":\n" .. (user or "unknown")
  end
  if type(user) ~= "table" then
    return nil, path .. " must return a table, got " .. type(user)
  end

  -- Working copies of the core tables: per-call, so a plugin config file can
  -- never leak defaults into the next load.
  local defaults = deep_copy(base_defaults)
  local schema = deep_copy(base_schema)

  local pdir = (plugin_dir ~= nil) and plugin_dir or PLUGIN_CONFIG_DIR
  local ok2, perr = apply_plugin_configs(pdir, defaults, schema)
  if not ok2 then
    return nil, perr
  end

  local result = deep_copy(defaults)
  merge(result, user)

  local errors = {}
  for k, v in pairs(result) do
    local expected = schema[k]
    if expected and type(v) ~= expected then
      table.insert(errors, "'" .. k .. "': expected " .. expected .. ", got " .. type(v))
    end
  end

  if #errors > 0 then
    return nil, "validation errors:\n  " .. table.concat(errors, "\n  ")
  end

  return result, nil
end

return config
