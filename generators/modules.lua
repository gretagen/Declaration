local gen = {}
gen.name = "modules"

function gen.plan(cfg, sync)
  local path = "/etc/conf.d/modules"
  local content = sync.read_file(path)

  if #cfg.modules == 0 then return {} end

  local desired = "-- managed by haliade-synchronize\n"
  for _, mod in ipairs(cfg.modules) do
    desired = desired .. "module=\"" .. mod .. "\"\n"
  end

  if content == desired then return {} end

  return {
    sync.change("~", "modules", "/etc/conf.d/modules", "update kernel modules list",
      function() sync.write_file(path, desired) end),
  }
end

return gen
