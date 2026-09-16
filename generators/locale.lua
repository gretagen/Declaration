local gen = {}
gen.name = "locale"

function gen.plan(cfg, sync)
  if not cfg.locale or cfg.locale == "" then return {} end

  local current = sync.read_file("/etc/locale.conf")
  local desired = "LANG=" .. cfg.locale .. "\n"
  if current == desired then return {} end

  local generated = sync.shell_output("locale -a 2>/dev/null"):match(cfg.locale)

  return {
    sync.change("~", "locale", "/etc/locale.conf",
      generated and "update locale.conf" or "generate + set " .. cfg.locale,
      function()
        if not generated then
          sync.shell("locale-gen " .. cfg.locale .. " 2>/dev/null || true")
        end
        sync.write_file("/etc/locale.conf", desired)
      end),
  }
end

return gen
