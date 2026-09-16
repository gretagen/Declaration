#!/bin/bash
# iniswap handler: runit

BUILD_DIR="/tmp/initsys"

install_runit() {
    # Check if already installed
    if [ -x /sbin/runit-init ]; then
        echo "  runit is already installed."
        return
    fi

    local cache="/var/cache/init"
    mkdir -p "$cache" "$BUILD_DIR"

    # Download (cached)
    if [ ! -f "$cache/runit-2.3.1.tar.gz" ]; then
        echo "  Downloading runit..."
        curl -L "https://smarden.org/runit/runit-2.3.1.tar.gz" \
             -o "$cache/runit-2.3.1.tar.gz" || {
            echo "Error: failed to download runit." >&2
            exit 1
        }
    fi

    # Extract to dedicated build directory
    rm -rf "$BUILD_DIR/runit"
    mkdir -p "$BUILD_DIR/runit"
    tar xzf "$cache/runit-2.3.1.tar.gz" -C "$BUILD_DIR/runit" || {
        echo "Error: failed to extract runit." >&2
        exit 1
    }

    # Find the source directory containing package/compile
    local compile_script
    compile_script=$(find "$BUILD_DIR/runit" -name "compile" -path "*/package/compile" 2>/dev/null | head -1)
    if [ -z "$compile_script" ]; then
        echo "Error: package/compile not found in extracted source." >&2
        exit 1
    fi
    srcdir=$(dirname "$(dirname "$compile_script")")
    cd "$srcdir" || {
        echo "Error: failed to enter runit source." >&2
        exit 1
    }

    # Build using runit's package/compile
    ./package/compile || {
        echo "Error: failed to build runit." >&2
        exit 1
    }

    # Install binaries to /sbin/
    cp command/* /sbin/ || {
        echo "Error: failed to install runit binaries." >&2
        exit 1
    }

    rm -rf "$BUILD_DIR/runit"
    echo "  runit installed."
}

generate_runit_services() {
    # Services are pre-installed in /etc/service/ in the rootfs.
    # Only create the runit stage scripts here.

    mkdir -p /etc/runit

    # Stage 1: early init (replaces OpenRC sysinit + boot runlevels)
    cat > /etc/runit/1 << 'STAGE1'
#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
# runit stage 1 — early init (Zerene OS)

# Mount virtual filesystems (skip if already mounted by initramfs)
mountpoint -q /proc || mount -t proc proc /proc
mountpoint -q /sys  || mount -t sysfs sysfs /sys
mountpoint -q /dev  || mount -t devtmpfs devtmpfs /dev
mountpoint -q /dev/pts || mount -t devpts devpts /dev/pts
mountpoint -q /run  || mount -t tmpfs tmpfs /run
mountpoint -q /tmp  || mount -t tmpfs tmpfs /tmp

# Hostname
hostname="$(cat /etc/hostname 2>/dev/null || echo zerene)"
hostname "$hostname"

# Keymaps
if [ -f /etc/conf.d/keymaps ]; then
    . /etc/conf.d/keymaps
    loadkeys "$keymap" 2>/dev/null || true
fi

# Console font (skip — causes screen clearing during boot)
# if [ -f /etc/conf.d/consolefont ]; then
#     . /etc/conf.d/consolefont
#     setfont "$consolefont" 2>/dev/null || true
# fi

# Hardware clock
if [ -f /etc/conf.d/hwclock ]; then
    . /etc/conf.d/hwclock
    hwclock --hctosys 2>/dev/null || true
fi

# Load kernel modules
if [ -f /etc/conf.d/modules ]; then
    . /etc/conf.d/modules
    for mod in $modules; do
        modprobe "$mod" 2>/dev/null || true
    done
fi

# Sysctl
sysctl -p 2>/dev/null || true

# Swap
swapon -a 2>/dev/null || true

# Filesystem check
fsck -p 2>/dev/null || true

# Mount root read/write
mount -o remount,rw / 2>/dev/null || true

# Mount local filesystems
mount -a 2>/dev/null || true

# Seed RNG
if [ -d /var/lib/seedrng ]; then
    seedrng 2>/dev/null || true
fi

# Runtime directories required by services
mkdir -p /run/dbus /run/udev /run/NetworkManager /run/wpa_supplicant

# udev — start early so devices (esp. NICs/wifi) exist before
# longrun services such as NetworkManager come up.
if [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon 2>/dev/null || /sbin/udevd -d 2>/dev/null || true
    udevadm trigger --action=add --type=subsystems 2>/dev/null || true
    udevadm trigger --action=add --type=devices 2>/dev/null || true
    udevadm trigger --action=change --type=devices 2>/dev/null || true
    udevadm settle --timeout=30 2>/dev/null || true
fi

# Create utmp/wtmp
touch /var/run/utmp /var/log/wtmp 2>/dev/null || true

# Clean /tmp
rm -rf /tmp/* 2>/dev/null || true

# Setup X11 sockets
rm -rf /tmp/.ICE-unix /tmp/.X11-unix
mkdir -p /tmp/.ICE-unix /tmp/.X11-unix
chmod 1777 /tmp/.ICE-unix /tmp/.X11-unix

exit 0
STAGE1
    chmod +x /etc/runit/1

    # Stage 2: service supervisor
    cat > /etc/runit/2 << 'STAGE2'
#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
exec runsvdir -P /etc/service
STAGE2
    chmod +x /etc/runit/2

    # Stage 3: shutdown
    cat > /etc/runit/3 << 'STAGE3'
#!/bin/sh
exec 2>&1
export PATH=/sbin:/usr/sbin:/bin:/usr/bin:/usr/local/bin
export SVDIR=/etc/service
# runit stage 3 — shutdown (Zerene OS)

# Stop all services
for svc in /etc/service/*/run; do
    [ -f "$svc" ] || continue
    name=$(basename "$(dirname "$svc")")
    sv stop "$name" 2>/dev/null || true
done

# Sync disks
sync

# Send TERM to all processes
kill -s TERM -1 2>/dev/null
sleep 1

# Send KILL to remaining
kill -s KILL -1 2>/dev/null
sleep 1

# Unmount filesystems
umount -a -r 2>/dev/null || true

# Final actions based on $1
# Use kernel syscalls via busybox/util-linux if available; avoid /sbin wrappers
case "${1:-reboot}" in
    reboot)   command -v busybox >/dev/null && exec busybox reboot -f; exec /usr/bin/reboot -f 2>/dev/null; echo b > /proc/sysrq-trigger ;;
    halt)     command -v busybox >/dev/null && exec busybox halt -f; echo o > /proc/sysrq-trigger ;;
    poweroff) command -v busybox >/dev/null && exec busybox poweroff -f; echo o > /proc/sysrq-trigger ;;
esac
STAGE3
    chmod +x /etc/runit/3

    echo "  Runit stage scripts created."
}
