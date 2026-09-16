local gen = {}
gen.name = "services"

local function detect_init(sync)
  local limine = sync.read_file("/boot/limine.conf") or ""
  local init_param = limine:match("init=(%S+)")
  if init_param then
    if init_param:match("runit%-init$") then return "runit"
    end
  end
  return "openrc"
end

-- Full run scripts for runit services, mirroring the templates shipped in
-- /etc/service. Runit supervises foreground processes; never daemonize.
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
}

local function runit_dir_for(svc)
  if svc == "NetworkManager" then return "networkmanager" end
  local tty = svc:match("^agetty%.tty(.*)$")
  if tty then return "agetty-tty" .. tty end
  return svc
end

local function runit_script_for(svc)
  local script = runit_scripts[svc]
  if script then return script end
  local tty = svc:match("^agetty%.tty(.*)$")
  if tty then
    return "#!/bin/sh\nexec 2>&1\nexec /sbin/agetty tty" .. tty .. " linux\n"
  end
  return nil
end

local function plan_openrc(cfg, sync)
  local changes = {}
  local rundir = "/etc/runlevels/default"

  local current = {}
  local ls = sync.shell_output("ls " .. rundir .. " 2>/dev/null")
  for s in ls:gmatch("[^\n]+") do
    current[s] = true
  end

  for _, svc in ipairs(cfg.services) do
    if not current[svc] then
      table.insert(changes, sync.change("+", "services", svc, "add to default runlevel",
        function() return sync.shell("rc-update add " .. svc .. " default") end))
    end
  end

  return changes
end

local function plan_runit(cfg, sync)
  local changes = {}
  local sv_dir = "/etc/service"

  local current = {}
  local ls = sync.shell_output("ls -d " .. sv_dir .. "/*/run 2>/dev/null")
  for path in ls:gmatch("[^\n]+") do
    local name = path:match(sv_dir .. "/([^/]+)/run")
    if name then current[name] = true end
  end

  for _, svc in ipairs(cfg.services) do
    local dir = runit_dir_for(svc)
    if not current[dir] then
      local script = runit_script_for(svc)
      if script then
        table.insert(changes, sync.change("+", "services", svc, "create runit service",
          function()
            local svc_dir = sv_dir .. "/" .. dir
            sync.shell("mkdir -p " .. svc_dir)
            sync.write_file(svc_dir .. "/run", script)
            return sync.shell("chmod +x " .. svc_dir .. "/run")
          end))
      else
        io.stderr:write("[warn] services: no runit template for '" .. svc .. "', skipping\n")
      end
    end
  end

  return changes
end

function gen.plan(cfg, sync)
  local init = detect_init(sync)

  if init == "runit" then
    return plan_runit(cfg, sync)
  else
    return plan_openrc(cfg, sync)
  end
end

return gen
