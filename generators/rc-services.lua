local gen = {}
gen.name = "rc-services"

-- OpenRC services: ensure each entry in ["rc-services"] is in the default
-- runlevel. Add-only — services dropped from the list are left enabled.

function gen.plan(cfg, sync)
  local changes = {}
  local rundir = "/etc/runlevels/default"

  local current = {}
  local ls = sync.shell_output("ls " .. rundir .. " 2>/dev/null")
  for s in ls:gmatch("[^\n]+") do
    current[s] = true
  end

  for _, svc in ipairs(cfg["rc-services"] or {}) do
    -- repower re-runs the add: rc-update on an already added service is a
    -- no-op, so forcing it is safe and keeps the rebuild honest
    local already = current[svc]
    if already and not sync.repower then
      -- already enabled
    elseif sync.read_file("/etc/init.d/" .. svc) then
      table.insert(changes, sync.change(already and "~" or "+", "rc-services", svc,
        already and "reapply : rc-update add" or "add to default runlevel",
        function() return sync.shell("rc-update add " .. svc .. " default") end))
    else
      io.stderr:write("[warn] rc-services: no OpenRC init script for '" .. svc .. "', skipping\n")
    end
  end

  return changes
end

return gen
