local gen = {}
gen.name = "env"

function gen.plan(cfg, sync)
  if not cfg.environment or next(cfg.environment) == nil then return {} end

  local lines = {}
  for k, v in pairs(cfg.environment) do
    table.insert(lines, k .. "=" .. v)
  end
  table.sort(lines)
  local desired = table.concat(lines, "\n") .. "\n"

  local current = sync.read_file("/etc/environment") or ""
  if current == desired then return {} end

  return {
    sync.change("~", "env", "/etc/environment", "update environment variables",
      function() sync.write_file("/etc/environment", desired) end),
  }
end

return gen
