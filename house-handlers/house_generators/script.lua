local gen = {}
gen.name = "script"

function gen.plan(cfg, house_sync)
  local changes = {}

  if not cfg.script or next(cfg.script) == nil then return {} end

  for path, content in pairs(cfg.script) do
    local current = house_sync.read_file(path)
    if current ~= content then
      local c = house_sync.change("~", "script", path, nil,
        function() 
        local ok, err = house_sync.write_file(path, content)
        if not ok then return false, err end
        return house_sync.shell("chmod +x " .. path) 
        end)
      -- chmod +x needs ownership even when the file itself is writable
      if not house_sync.writable_path(path)
          or (house_sync.file_exists(path) and not house_sync.owns(path)) then
        c.requires_root = true
      end
      table.insert(changes, c)
    end
  end

  return changes
end

return gen
