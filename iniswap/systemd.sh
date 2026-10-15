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
    # Units ship with the systemd package; nothing to generate beyond the
    # admin dirs and the Haliade getty drop-ins (getty must clear its own
    # tty — with the packaged --noclear a supervisor restart stacks a second
    # login prompt instead of replacing the first).
    mkdir -p /etc/systemd/system/multi-user.target.wants

    mkdir -p /etc/systemd/system/getty@.service.d
    cat > /etc/systemd/system/getty@.service.d/50-haliade.conf << 'GETTY'
# Haliade OS — getty must clear its own tty before prompting.
# The packaged ExecStart passes --noclear; with the flag a supervisor
# restart appends a second prompt instead of replacing the first, and the
# tty ends up with several stacked login lines. Same fix as the runit and
# dinit getty services.
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --noreset - ${TERM}
GETTY

    mkdir -p /etc/systemd/system/serial-getty@.service.d
    cat > /etc/systemd/system/serial-getty@.service.d/50-haliade.conf << 'SERIALGETTY'
# Haliade OS — getty must clear its own tty before prompting.
# The packaged ExecStart passes --noclear; with the flag a supervisor
# restart appends a second prompt instead of replacing the first, and the
# tty ends up with several stacked login lines. Same fix as the runit and
# dinit getty services.
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --noreset --keep-baud 115200,57600,38400,9600 - ${TERM}
SERIALGETTY

    echo "  systemd getty drop-ins installed."
}
