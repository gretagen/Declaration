local gen = {}
gen.name = "sysmd-services"

-- Systemd services: ensure each entry in ["sysmd-services"] is enabled via a
-- symlink in /etc/systemd/system/multi-user.target.wants. Add-only — services
-- dropped from the list are left enabled (not disabled).
--
-- Unit files ship with the systemd package (zeta); this generator only
-- toggles enablement, it never writes unit files. Names in the config use
-- the shared Haliade service names (agetty.tty1, logind, ...) so one list
-- reads the same across inits; they map to standard systemd units:
--   sshd         -> sshd.service
--   iwd          -> iwd.service
--   logind       -> systemd-logind.service   (NOT elogind: under systemd the
--                  login1 bus name is served by systemd-logind, and elogind
--                  is bridged off — see /usr/libexec/haliade/logind-bridge)
--   rfkill       -> systemd-rfkill.service
--   agetty.ttyN  -> getty@ttyN.service
--   agetty.ttyS0 -> serial-getty@ttyS0.service
-- Anything else falls back to "<name>.service" and is skipped with a warning
-- when no such unit exists.

local unit_for = {
  logind = "systemd-logind.service",
  rfkill = "systemd-rfkill.service",
}

local function unit_for_service(svc)
  local mapped = unit_for[svc]
  if mapped then return mapped end

  local tty = svc:match("^agetty%.tty(.+)$")
  if tty then
    if tty == "S0" then
      return "serial-getty@ttyS0.service"
    end
    return "getty@tty" .. tty .. ".service"
  end

  return svc .. ".service"
end

-- Instance units (getty@tty1.service) have no file on disk: they are
-- instantiated from a template (getty@.service). The enablement symlink is
-- named after the instance but points at the template, exactly what
-- `systemctl enable getty@tty1` creates. Non-instance units map to themselves.
local function unit_file_for(unit)
  local tmpl = unit:match("^([^@]+@)[^@]*%.service$")
  if tmpl then
    return tmpl .. ".service"
  end
  return unit
end

function gen.plan(cfg, sync)
  local changes = {}
  local wants_dir = "/etc/systemd/system/multi-user.target.wants"
  local units_dir = "/usr/lib/systemd/system"

  local enabled = {}
  local ls = sync.shell_output("ls -1 " .. wants_dir .. " 2>/dev/null")
  for name in ls:gmatch("[^\n]+") do
    enabled[name] = true
  end

  for _, svc in ipairs(cfg["sysmd-services"] or {}) do
    local unit = unit_for_service(svc)
    local unit_file = unit_file_for(unit)
    local already = enabled[unit]
    if already and not sync.repower then
      -- already enabled
    elseif sync.read_file(units_dir .. "/" .. unit_file) then
      table.insert(changes, sync.change(already and "~" or "+", "sysmd-services", svc,
        already and ("reapply : enable " .. unit) or ("enable " .. unit),
        function()
          sync.shell("mkdir -p " .. wants_dir)
          return sync.shell("ln -sfn " .. units_dir .. "/" .. unit_file ..
            " " .. wants_dir .. "/" .. unit)
        end))
    else
      io.stderr:write("[warn] sysmd-services: no systemd unit for '" .. svc
        .. "' (" .. unit_file .. "), skipping\n")
    end
  end

  return changes
end

return gen
