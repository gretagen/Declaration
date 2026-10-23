local gen = {}
gen.name = "shepherd-services"

-- Shepherd services: ensure each entry in ["shepherd-services"] has a
-- drop-in definition under /etc/shepherd.d/*.scm. Add-only — services
-- dropped from the list are left alone (not stopped), like every sibling.
--
-- The drop-ins are self-registering (haliade-service! is defined by the
-- base /etc/shepherd.scm that the iniswap handler generates). When shepherd
-- is really PID 1, a new or changed drop-in is applied live with
-- 'herd load root' and then started (repower also restarts it). During the
-- swap window — shepherd declared in limine.conf but not yet PID 1 — there
-- is no shepherd to talk to, so the file is written and takes effect on the
-- next boot, exactly like the universal shutdown wrapper skips init tools
-- that cannot work yet.
--
-- Templates are byte-identical with shepherd-services/shepherd/dropins/*.
-- Daemon argv mirrors the dinit-services definitions (which in turn mirror
-- runit/OpenRC), so one service reads the same across inits.

local shepherd_dir = "/etc/shepherd.d"

local function shepherd_is_pid1(sync)
  local comm = sync.read_file("/proc/1/comm") or ""
  return comm:match("^[^\n]+") == "shepherd"
end

-- Getty drop-in template (@NAME@/@ARGV@ placeholders): rendered text stays
-- byte-identical with shepherd-services/shepherd/dropins/agetty.*.
local getty_template = [=[
;; @NAME@ — login prompt. No --noclear (agetty must clear before
;; prompting; with the flag a supervisor restart stacks a second prompt).
;; The bounded bus wait replaces dinit's soft waits-for: the prompt comes up
;; once the boot daemons are up, or after 30 seconds either way (fails-open,
;; like the runit sv status loop).
(haliade-service!
 '@NAME@
 (service
  '(@NAME@)
  #:requirement '(boot)
  #:start (make-forkexec-constructor
           '("/bin/sh" "-c"
             "n=0; until [ -S /run/dbus/system_bus_socket ]; do n=$((n+1)); [ $n -ge 30 ] && break; sleep 1; done; exec @ARGV@"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=]

local function getty_dropin(tty)
  local name = "agetty.tty" .. tty
  local argv
  if tty == "S0" then
    argv = "/sbin/agetty -L ttyS0 115200 vt100"
  else
    argv = "/sbin/agetty tty" .. tty .. " 38400 linux"
  end
  return (getty_template:gsub("@NAME@", name):gsub("@ARGV@", argv))
end

local dropins = {
  dbus = [=[
;; dbus — D-Bus system message bus.
;; Mirrors the dinit service: chown /run/dbus to messagebus, then run in the
;; foreground (--nofork makes dbus-daemon bind the system bus socket itself).
(haliade-service!
 'dbus
 (service
  '(dbus)
  #:requirement '(boot)
  #:start (make-forkexec-constructor
           '("/bin/sh" "-c"
             "chown messagebus:messagebus /run/dbus 2>/dev/null || true; exec /usr/bin/dbus-daemon --system --nofork --nopidfile"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=],

  connmand = [=[
;; connmand — Connection Manager (ethernet-first, as in OpenRC/dinit).
;; No bus-wait wrapper: connmand tolerates a late bus and retries on its own;
;; the #:requirement only orders it after dbus, like dinit's depends-on.
(haliade-service!
 'connmand
 (service
  '(connmand)
  #:requirement '(boot dbus)
  #:start (make-forkexec-constructor '("/usr/sbin/connmand" "-n"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=],

  iwd = [=[
;; iwd — iNet Wireless Daemon.
;; Mirrors the runit/dinit services: unblock rfkill, prepare /var/lib/iwd,
;; bind-mount it over /usr/var/lib/iwd, export STATE_DIRECTORY, then run
;; iwd. The bounded bus wait is the fails-open stand-in for dinit's
;; depends-on dbus readiness.
(haliade-service!
 'iwd
 (service
  '(iwd)
  #:requirement '(boot dbus)
  #:start (make-forkexec-constructor
           '("/bin/sh" "-c"
             "/sbin/rfkill unblock all 2>/dev/null || true; [ -d /var/lib/iwd ] || mkdir -p /var/lib/iwd 2>/dev/null; chmod 700 /var/lib/iwd 2>/dev/null; [ -d /usr/var/lib/iwd ] || mkdir -p /usr/var/lib/iwd 2>/dev/null; mountpoint -q /usr/var/lib/iwd 2>/dev/null || mount --bind /var/lib/iwd /usr/var/lib/iwd 2>/dev/null; n=0; until [ -S /run/dbus/system_bus_socket ]; do n=$((n+1)); [ $n -ge 5 ] && break; sleep 1; done; exec env STATE_DIRECTORY=/var/lib/iwd /usr/libexec/iwd"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=],

  elogind = [=[
;; elogind — user seat manager (foreground, as in OpenRC/runit/dinit).
;; /run/systemd is already created by sysinit.sh; the bounded bus wait is
;; the fails-open stand-in for dinit's pipefd readiness on dbus.
(haliade-service!
 'elogind
 (service
  '(elogind)
  #:requirement '(boot dbus)
  #:start (make-forkexec-constructor
           '("/bin/sh" "-c"
             "mkdir -p /run/systemd; rm -f /run/elogind.pid; n=0; until [ -S /run/dbus/system_bus_socket ]; do n=$((n+1)); [ $n -ge 5 ] && break; sleep 1; done; exec /usr/libexec/elogind"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=],

  sshd = [=[
;; sshd — OpenSSH server, foreground with stderr logging (-D -e), same argv
;; as the runit/dinit services; the -t precheck and /run/sshd mirror dinit's
;; sh -c wrapper. No bus dependency, like dinit (depends-on sysinit only).
(haliade-service!
 'sshd
 (service
  '(sshd)
  #:requirement '(boot)
  #:start (make-forkexec-constructor
           '("/bin/sh" "-c"
             "/usr/sbin/sshd -t 2>/dev/null; [ -d /run/sshd ] || mkdir -p /run/sshd 2>/dev/null; exec /usr/sbin/sshd -D -e"))
  #:stop (make-kill-destructor)
  #:respawn? #t))
]=],
}

local function dropin_for(svc)
  if dropins[svc] then return dropins[svc] end
  local tty = svc:match("^agetty%.tty(.+)$")
  if tty then return getty_dropin(tty) end
  return nil
end

function gen.plan(cfg, sync)
  local changes = {}

  local current = {}
  local ls = sync.shell_output("ls -1 " .. shepherd_dir .. "/*.scm 2>/dev/null")
  for name in ls:gmatch("([^/\n]+)%.scm") do
    current[name] = true
  end

  for _, svc in ipairs(cfg["shepherd-services"] or {}) do
    local already = current[svc]
    if already and not sync.repower then
      -- already in place
    else
      local script = dropin_for(svc)
      if script then
        table.insert(changes, sync.change(already and "~" or "+", "shepherd-services", svc,
          already and "reapply : rewrite drop-in" or "write drop-in",
          function()
            sync.shell("mkdir -p " .. shepherd_dir)
            local path = shepherd_dir .. "/" .. svc .. ".scm"
            if not sync.write_file(path, script) then
              return false
            end
            -- Live-apply only when shepherd really is PID 1 (see header).
            if not shepherd_is_pid1(sync) then
              sync.vprint("shepherd is not PID 1: '%s' applies on next boot", svc)
              return true
            end
            if not sync.shell("herd load root " .. path) then
              return false
            end
            -- A freshly written drop-in is registered but not running yet;
            -- under repower an already-known service is bounced so the new
            -- definition actually takes over.
            if not already then
              return sync.shell("herd start " .. svc)
            elseif sync.repower then
              return sync.shell("herd restart " .. svc)
            end
            return true
          end))
      else
        io.stderr:write("[warn] shepherd-services: no shepherd template for '" .. svc .. "', skipping\n")
      end
    end
  end

  return changes
end

return gen
