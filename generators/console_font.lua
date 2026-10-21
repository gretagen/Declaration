local gen = {}
gen.name = "console_font"

-- Console font: converge BOTH config shapes, because the inits read
-- different files — OpenRC/runit/dinit apply the font via the kbd
-- scripts reading /etc/conf.d/consolefont; systemd's
-- systemd-vconsole-setup reads FONT= from /etc/vconsole.conf. Writing
-- both keeps the declared font identical across init swaps.

function gen.plan(cfg, sync)
  local changes = {}

  local content = sync.read_file("/etc/conf.d/consolefont") or ""
  local current = content:match('consolefont%s*=%s*"([^"]+)"')
    or content:match('consolefont=%s*(%S+)') or "latarcyrheb-sun16"

  if sync.differs(current, cfg.console_font) then
    table.insert(changes, sync.change("~", "console_font", "/etc/conf.d/consolefont",
      current .. "  →  " .. cfg.console_font,
      function()
        local new = content:gsub('consolefont%s*=%s*"[^"]*"',
          'consolefont="' .. cfg.console_font .. '"')
        if not content:find('consolefont%s*=') then
          new = content .. '\nconsolefont="' .. cfg.console_font .. '"\n'
        end
        sync.write_file("/etc/conf.d/consolefont", new)
      end))
  end

  local vc = sync.read_file("/etc/vconsole.conf") or ""
  local cur_vc = vc:match("FONT%s*=%s*(%S+)")

  if sync.differs(cur_vc, cfg.console_font) then
    table.insert(changes, sync.change("~", "console_font", "/etc/vconsole.conf",
      (cur_vc or "(unset)") .. "  →  " .. cfg.console_font,
      function()
        local new
        if vc:find("FONT%s*=") then
          new = vc:gsub("FONT%s*=%s*%S+", "FONT=" .. cfg.console_font)
        else
          new = vc .. "FONT=" .. cfg.console_font .. "\n"
        end
        sync.write_file("/etc/vconsole.conf", new)
      end))
  end

  return changes
end

return gen
