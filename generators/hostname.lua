local gen = {}
gen.name = "hostname"

function gen.plan(cfg, sync)
  local current = sync.read_file("/etc/hostname")
  if current ~= nil then current = current:gsub("%s+$", "") end

  if current == cfg.hostname then return {} end

  return {
    sync.change("~", "hostname", "/etc/hostname",
      current and (current .. "  →  " .. cfg.hostname) or "set to " .. cfg.hostname,
      function()
        sync.write_file("/etc/hostname", cfg.hostname .. "\n")
        sync.write_file("/etc/conf.d/hostname",
          "# managed by haliade-synchronize\nhostname=\"" .. cfg.hostname .. "\"\n")
      end),
  }
end

return gen
