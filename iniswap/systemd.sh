#!/bin/bash
# iniswap handler: systemd

install_systemd() {
    # The zeta systemd package provides the daemon + userspace tools.
    # Check the two pieces the rest of the port actually needs: the PID1
    # entry point (/sbin/systemd — kernel init= points here, matching the
    # /sbin layout of the other three inits) and systemctl (universal
    # shutdown/reboot wrapper dispatches through it).
    if [ -x /sbin/systemd ] && [ -x /usr/bin/systemctl ]; then
        echo "  systemd is already installed."
        return
    fi

    echo "  Installing systemd via zeta..."
    zeta -provide --pass systemd
}

generate_systemd_services() {
    # Units ship with the systemd package; everything generated here is a
    # Haliade admin drop-in under /etc/systemd/system (survives package
    # reinstalls of /usr/lib/systemd).

    mkdir -p /etc/systemd/system/multi-user.target.wants

    # --- system bus -------------------------------------------------------
    # Type=dbus's name-watch for org.freedesktop.DBus never completes on
    # this rootfs even with the daemon alive: the job burns the whole
    # start timeout, then every retry fails behind the first instance
    # holding the socket. Run the classic self-binding daemon as
    # Type=simple (the OpenRC/runit invocation) and pull it in directly:
    # "started" = process up, no bus name-watch involved.
    mkdir -p /etc/systemd/system/dbus.service.d
    cat > /etc/systemd/system/dbus.service.d/50-haliade.conf << 'DBUS'
[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p /run/dbus
ExecStart=
ExecStart=/usr/bin/dbus-daemon --system --nofork --nopidfile
DBUS

    # The daemon binds /run/dbus/system_bus_socket itself, so the socket
    # unit must not hold that path (or the bind fails). Redirect it to an
    # unused path; it stays orderable for Requires=dbus.socket.
    mkdir -p /etc/systemd/system/dbus.socket.d
    cat > /etc/systemd/system/dbus.socket.d/50-haliade.conf << 'DBUSSOCKET'
[Socket]
ListenStream=
ListenStream=/run/dbus/activation-unused
DBUSSOCKET

    # dbus.service is started by a direct wants symlink, not socket
    # activation, so "After=dbus.socket" no longer implies the daemon is
    # up. Order the bus clients after the daemon itself.
    mkdir -p /etc/systemd/system/systemd-logind.service.d
    cat > /etc/systemd/system/systemd-logind.service.d/50-haliade.conf << 'LOGIND'
[Unit]
Wants=dbus.service
After=dbus.service
LOGIND

    mkdir -p /etc/systemd/system/iwd.service.d
    cat > /etc/systemd/system/iwd.service.d/50-haliade.conf << 'IWD'
[Unit]
After=dbus.service
IWD

    ln -sfn ../../../../usr/lib/systemd/system/dbus.service \
        /etc/systemd/system/multi-user.target.wants/dbus.service

    # --- network ------------------------------------------------------------
    # Run the same stack the other three inits run: connmand does DHCP (wired)
    # and writes /etc/resolv.conf; iwd handles wireless (already enabled,
    # picked up by connman as its wifi backend over D-Bus). systemd-networkd
    # is deliberately NOT used: it never writes /etc/resolv.conf without
    # systemd-resolved, and it would race connman for the interface.
    cat > /usr/lib/systemd/system/connman.service << 'CONNMAN'
[Unit]
Description=Connection service
Documentation=man:connmand.service(8)
Wants=dbus.service
After=dbus.service

[Service]
Type=simple
ExecStart=/usr/sbin/connmand -n

[Install]
WantedBy=multi-user.target
CONNMAN

    ln -sfn ../../../../usr/lib/systemd/system/connman.service \
        /etc/systemd/system/multi-user.target.wants/connman.service

    # --- console font / keymap ----------------------------------------------
    # systemd-vconsole-setup reads /etc/vconsole.conf (the other inits read
    # /etc/conf.d/{consolefont,keymaps}). Mirror the declared values so the
    # swap doesn't lose the tty font/keymap.
    local font keymap
    font=$(sed -n 's/^consolefont="\([^"]*\)"/\1/p' /etc/conf.d/consolefont 2>/dev/null)
    keymap=$(sed -n 's/^keymap="\([^"]*\)"/\1/p' /etc/conf.d/keymaps 2>/dev/null)
    {
        [ -n "$keymap" ] && echo "KEYMAP=$keymap"
        [ -n "$font" ] && echo "FONT=$font"
    } > /etc/vconsole.conf

    # --- gettys -----------------------------------------------------------
    # Nothing to generate: the stock getty@/serial-getty@ units work as-is
    # once /usr/bin/agetty exists (the packaged ExecStart=-/usr/bin/agetty
    # silently swallowed the missing binary — "-" ignores the failure).
    # util-linux's agetty ships there; do not add drop-ins here again
    # without a failing case to justify them.

    echo "  systemd service drop-ins installed (dbus, logind, iwd)."
}
