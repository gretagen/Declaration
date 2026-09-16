#!/bin/bash
# iniswap handler: openrc

install_openrc() {
    if [ ! -x /sbin/openrc-init ]; then
        echo "Error: /sbin/openrc-init not found." >&2
        exit 1
    fi
    echo "  OpenRC is already installed."
}

generate_openrc_services() {
    echo "  OpenRC services already exist — nothing to generate."
}
