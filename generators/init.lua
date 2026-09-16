local gen = {}
gen.name = "init"

local init_bins = {
  openrc = nil,
  runit  = "/sbin/runit-init",
}

function gen.plan(cfg, sync)
  local changes = {}
  local desired = cfg.init

  local limine = "/boot/limine.conf"
  local content = sync.read_file(limine)
  if not content then
    io.stderr:write("[warn] init: cannot read " .. limine .. "\n")
    return {}
  end

  local current = "openrc"
  local init_param = content:match("init=(%S+)")
  if init_param then
    for name, path in pairs(init_bins) do
      if path and init_param == path then
        current = name
        break
      end
    end
    if current == "openrc" and init_param ~= "" then
      current = "unknown"
    end
  end

  if current == desired then
    return {}
  end

  if desired == "unknown" then
    io.stderr:write("[warn] init: cannot swap to unknown init\n")
    return {}
  end

  table.insert(changes, sync.change("~", "init", desired,
    "swap init from " .. current .. " to " .. desired,
    function(_, s)
      local ok = s.shell("iniswap --pass " .. desired)
      if not ok then
        io.stderr:write("[error] init: iniswap " .. desired .. " failed\n")
      end
      return ok
    end))

  return changes
end

return gen
