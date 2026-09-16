local gen = {}
gen.name = "hwclock"

function gen.plan(cfg, sync)
  local content = sync.read_file("/etc/conf.d/hwclock") or ""
  local current = content:match('clock%s*=%s*"([^"]+)"') or "UTC"

  if current == cfg.hwclock then return {} end

  local value = cfg.hwclock == "local" and "local" or "UTC"

  return {
    sync.change("~", "hwclock", "/etc/conf.d/hwclock",
      current .. "  →  " .. value,
      function()
        local new = content:gsub('clock%s*=%s*"[^"]*"', 'clock="' .. value .. '"')
        if not content:find('clock%s*=') then
          new = content .. '\nclock="' .. value .. '"\n'
        end
        sync.write_file("/etc/conf.d/hwclock", new)
      end),
  }
end

return gen
