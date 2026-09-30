#!/bin/bash
# iniswap handler: dinit

install_dinit() {
    # Check if already installed
    if [ -x /usr/sbin/dinit ]; then
        echo "  dinit is already installed."
        return
    fi

    echo "  Installing dinit via zeta..."
    zeta -provide --pass dinit
}

generate_dinit_services() {
    # Services are pre-installed in /etc/dinit.d/ in the rootfs (by
    # dinit-services/install.sh). Nothing to generate here beyond making
    # sure the service scripts are executable and boot.d exists.
    mkdir -p /etc/dinit.d/boot.d
    chmod +x /etc/dinit.d/scripts/*.sh 2>/dev/null || true

    echo "  dinit service bindings ready."
}