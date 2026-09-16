local gen = {}
gen.name = "console_font"

function gen.plan(cfg, sync)
  local content = sync.read_file("/etc/conf.d/consolefont") or ""
  local current = content:match('consolefont%s*=%s*"([^"]+)"')
    or content:match('consolefont=%s*(%S+)') or "latarcyrheb-sun16"

  if current == cfg.console_font then return {} end

  return {
    sync.change("~", "console_font", "/etc/conf.d/consolefont",
      current .. "  →  " .. cfg.console_font,
      function()
        local new = content:gsub('consolefont%s*=%s*"[^"]*"',
          'consolefont="' .. cfg.console_font .. '"')
        if not content:find('consolefont%s*=') then
          new = content .. '\nconsolefont="' .. cfg.console_font .. '"\n'
        end
        sync.write_file("/etc/conf.d/consolefont", new)
      end),
  }
end

return gen
