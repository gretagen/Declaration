local gen = {}
gen.name = "edit"

function gen.plan(cfg, sync)
  local changes = {}

  if not cfg.edit or next(cfg.edit) == nil then return {} end

  for path, content in pairs(cfg.edit) do
    local current = sync.read_file(path)
    if current ~= content then
      table.insert(changes, sync.change("~", "edit", path, nil,
        function() return sync.write_file(path, content) end))
    end
  end

  return changes
end

return gen
