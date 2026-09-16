local gen = {}
gen.name = "keymap"

function gen.plan(cfg, sync)
  local content = sync.read_file("/etc/conf.d/keymaps") or ""
  local current = content:match('keymap%s*=%s*"([^"]+)"') or "us"

  if current == cfg.keymap then return {} end

  return {
    sync.change("~", "keymap", "/etc/conf.d/keymaps",
      current .. "  →  " .. cfg.keymap,
      function()
        local new = content:gsub('keymap%s*=%s*"[^"]*"', 'keymap="' .. cfg.keymap .. '"')
        if not content:find('keymap%s*=') then
          new = content .. '\nkeymap="' .. cfg.keymap .. '"\n'
        end
        sync.write_file("/etc/conf.d/keymaps", new)
      end),
  }
end

return gen
