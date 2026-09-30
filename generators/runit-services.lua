local gen = {}
gen.name = "runit-services"

-- Runit services: ensure each entry in ["runit-services"] has a supervised
-- service directory under /etc/service with an executable run script.
-- Add-only — services dropped from the list are left alone (not stopped).
--
-- Directory names must match what the rootfs ships (agetty.tty1, not
-- agetty-tty1): renaming the dir would create a second getty competing
-- for the same tty.

local runit_dir_for = function(svc)
  if svc == "NetworkManager" then return "networkmanager" end
  return svc
end

-- Full run scripts mirroring the templates shipped in /etc/service.
-- Runit supervises foreground processes; never daemonize.
local runit_scripts = {
  dbus = [[#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
rm -f /run/dbus/pid
mkdir -p /run/dbus
chown messagebus:messagebus /run/dbus 2>/dev/null || true
exec /usr/bin/dbus-daemon --system --nofork --nopidfile
]],
  NetworkManager = [[#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
mkdir -p /var/lib/NetworkManager /run/dbus /run/NetworkManager
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    [ -S /run/dbus/system_bus_socket ] && [ -e /run/udev/control ] && break
    [ -S /var/run/dbus/system_bus_socket ] && [ -e /run/udev/control ] && break
    sleep 1
done
[ -S /run/dbus/system_bus_socket ] || [ -S /var/run/dbus/system_bus_socket ] || exit 1
exec /usr/sbin/NetworkManager --no-daemon
]],
  elogind = [[#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
mkdir -p /run/systemd
rm -f /run/elogind.pid
for i in 1 2 3 4 5; do
    [ -S /var/run/dbus/system_bus_socket ] && break
    sleep 1
done
[ -S /var/run/dbus/system_bus_socket ] || exit 1
exec /usr/libexec/elogind
]],
  sshd = [[#!/bin/sh
exec 2>&1
exec /usr/sbin/sshd -D
]],
  wpa_supplicant = [[#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
mkdir -p /run/wpa_supplicant
exec /usr/sbin/wpa_supplicant -u -s -O /run/wpa_supplicant
]],
  iwd = [[#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin

# wlan/bt radios unblocked (mirrors OpenRC iwd start_pre)
/sbin/rfkill unblock all 2>/dev/null || true

# iwd state dir (mirrors OpenRC iwd start_pre)
mkdir -p /var/lib/iwd 2>/dev/null || true
chmod 700 /var/lib/iwd 2>/dev/null || true
mkdir -p /usr/var/lib/iwd 2>/dev/null || true
if ! mountpoint -q /usr/var/lib/iwd 2>/dev/null; then
    mount --bind /var/lib/iwd /usr/var/lib/iwd 2>/dev/null || true
fi

export STATE_DIRECTORY=/var/lib/iwd
exec /usr/libexec/iwd
]],
  connmand = [[#!/bin/sh
exec 2>&1
exec /usr/sbin/connmand -n
]],
}

-- agetty: mirror the shipped run scripts — start LAST (bounded 30s wait on
-- the supervised daemons) so the login prompt never overlaps boot activity.
local function agetty_script(tty)
  return "#!/bin/sh\n" ..
    "exec 2>&1\n" ..
    "DEPS=\"dbus sshd iwd connmand elogind\"\n" ..
    "if command -v sv >/dev/null 2>&1; then\n" ..
    "    for dep in $DEPS; do\n" ..
    "        [ -d \"/etc/service/$dep\" ] || continue\n" ..
    "        n=0\n" ..
    "        until sv status \"/etc/service/$dep\" 2>/dev/null | grep -q \"^run:\"; do\n" ..
    "            n=$((n+1)); [ \"$n\" -ge 30 ] && break\n" ..
    "            sleep 1\n" ..
    "        done\n" ..
    "    done\n" ..
    "fi\n" ..
    "exec /sbin/agetty " .. tty .. "\n"
end

local function runit_script_for(svc)
  local script = runit_scripts[svc]
  if script then return script end

  local tty = svc:match("^agetty%.tty(.+)$")
  if tty then
    if tty == "S0" then
      return agetty_script("-L ttyS0 115200 vt100")
    end
    return agetty_script("tty" .. tty .. " 38400 linux")
  end

  return nil
end

function gen.plan(cfg, sync)
  local changes = {}
  local sv_dir = "/etc/service"

  local current = {}
  local ls = sync.shell_output("ls -d " .. sv_dir .. "/*/run 2>/dev/null")
  for path in ls:gmatch("[^\n]+") do
    local name = path:match(sv_dir .. "/([^/]+)/run")
    if name then current[name] = true end
  end

  for _, svc in ipairs(cfg["runit-services"] or {}) do
    local dir = runit_dir_for(svc)
    if current[dir] then
      -- already supervised
    else
      local script = runit_script_for(svc)
      if script then
        table.insert(changes, sync.change("+", "runit-services", svc, "create runit service",
          function()
            local svc_dir = sv_dir .. "/" .. dir
            sync.shell("mkdir -p " .. svc_dir)
            sync.write_file(svc_dir .. "/run", script)
            return sync.shell("chmod +x " .. svc_dir .. "/run")
          end))
      else
        io.stderr:write("[warn] runit-services: no runit template for '" .. svc .. "', skipping\n")
      end
    end
  end

  return changes
end

return gen
