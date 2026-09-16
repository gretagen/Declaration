local gen = {}
gen.name = "timezone"

function gen.plan(cfg, sync)
  local target = "/usr/share/zoneinfo/" .. cfg.timezone
  local current_link = sync.shell_output("readlink -f /etc/localtime 2>/dev/null")

  if current_link == target then return {} end

  return {
    sync.change("~", "timezone", "/etc/localtime",
      current_link .. "  →  " .. target,
      function()
        sync.shell("ln -sf '" .. target .. "' /etc/localtime")
      end),
  }
end

return gen
