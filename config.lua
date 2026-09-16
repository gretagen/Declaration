local config = {}

local defaults = {
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

  packages  = {},
  subspaces = {},
  modules   = {},
  services = { "sshd", "NetworkManager", "elogind" },
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

local schema = {
  hostname = "string", timezone = "string", locale = "string",
  hwclock = "string", keymap = "string", console_font = "string",
  root_partuuid = "string", kernel_cmdline = "string",
  environment = "table",
  boot = "table", init = "string",
  packages = "table", subspaces = "table", modules = "table", services = "table", users = "table",
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

function config.load(path)
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
