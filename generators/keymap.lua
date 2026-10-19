local gen = {}
gen.name = "keymap"

-- Keymap: converge BOTH config shapes, like console_font —
-- /etc/conf.d/keymaps (OpenRC/runit/dinit kbd scripts) and
-- KEYMAP= in /etc/vconsole.conf (systemd-vconsole-setup).

function gen.plan(cfg, sync)
  local changes = {}

  local content = sync.read_file("/etc/conf.d/keymaps") or ""
  local current = content:match('keymap%s*=%s*"([^"]+)"') or "us"

  if current ~= cfg.keymap then
    table.insert(changes, sync.change("~", "keymap", "/etc/conf.d/keymaps",
      current .. "  →  " .. cfg.keymap,
      function()
        local new = content:gsub('keymap%s*=%s*"[^"]*"', 'keymap="' .. cfg.keymap .. '"')
        if not content:find('keymap%s*=') then
          new = content .. '\nkeymap="' .. cfg.keymap .. '"\n'
        end
        sync.write_file("/etc/conf.d/keymaps", new)
      end))
  end

  local vc = sync.read_file("/etc/vconsole.conf") or ""
  local cur_vc = vc:match("KEYMAP%s*=%s*(%S+)")

  if cur_vc ~= cfg.keymap then
    table.insert(changes, sync.change("~", "keymap", "/etc/vconsole.conf",
      (cur_vc or "(unset)") .. "  →  " .. cfg.keymap,
      function()
        local new
        if vc:find("KEYMAP%s*=") then
          new = vc:gsub("KEYMAP%s*=%s*%S+", "KEYMAP=" .. cfg.keymap)
        else
          new = vc .. "KEYMAP=" .. cfg.keymap .. "\n"
        end
        sync.write_file("/etc/vconsole.conf", new)
      end))
  end

  return changes
end

return gen
