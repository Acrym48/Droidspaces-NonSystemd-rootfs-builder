# Dockerfile (Minimal, sysvinit)
# Stage 1: Build and customize the rootfs for development (Minimal - Devuan 6 Excalibur, sysvinit)
ARG TARGETPLATFORM
FROM arfshl/devuan:excalibur AS customizer

ENV DEBIAN_FRONTEND=noninteractive

# Update base system and enable non-free/contrib
RUN sed -i 's/main/main contrib non-free/g' /etc/apt/sources.list && \
    apt-get update && apt-get upgrade -y

# Copy custom scripts first
COPY scripts/download-firmware /usr/local/bin/

# Copy our bashrc script to the rootfs
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# Make scripts executable
RUN chmod +x /usr/local/bin/download-firmware /etc/profile.d/ds-aliases.sh

# Install Minimal package set
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # Init: sysvinit-core provides /sbin/init and SysV runlevel management
    sysvinit-core \
    # Core utilities
    bash \
    dialog \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    locales \
    bash-completion \
    udev \
    dbus \
    util-linux \
    # Basic tools requested by user
    git \
    nano \
    sudo \
    # Networking & SSH
    openssh-server \
    dhcpcd-base \
    net-tools \
    iptables \
    iputils-ping \
    iproute2 \
    dnsutils \
    # Procps for system monitoring
    procps \
    # Essential kernel module support
    kmod \
    && apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Configure iptables-legacy (MANDATORY for Android compatibility)
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# Configure locales, environment, SSH, and user setup
RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 && \
    # Configure SSH (Disable Root Login)
    mkdir -p /var/run/sshd /run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Remove default user if it exists
    deluser --remove-home debian || true

# Fix DHCP in the container (dhcpcd instead of systemd-networkd)
RUN printf '\n# Droidspaces: only manage ethernet-like interfaces\nallowinterfaces eth*\n' >> /etc/dhcpcd.conf

# Apply Android compatibility fixes (sysvinit and udev)
RUN <<EOF_RUN

# --- 1. General Fixes ---
# Android network group setup (required for socket access on Android kernels)
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# _apt needs aid_inet as primary group so apt works on Android
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

# Future users created with adduser automatically get network access
if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
fi

# --- 2. sysvinit fixes ---
# No VT gettys in a container: drop tty1-6, use the console only
sed -i 's|^\([1-6]:.*getty.*\)$|#\1|' /etc/inittab
grep -q '^c0:' /etc/inittab || echo 'c0:12345:respawn:/sbin/agetty --noclear console 115200 linux' >> /etc/inittab

# Ignore ctrl-alt-del and power events (power button on Android must not reboot the container)
sed -i 's|^\(ca:.*ctrlaltdel.*\)$|#\1|; s|^\(pf:.*\)$|#\1|; s|^\(pr:.*\)$|#\1|' /etc/inittab

# Map SIGPWR to runlevel 0 for clean container shutdown
grep -q '^pf:' /etc/inittab || echo 'pf::powerwait:/sbin/telinit 0' >> /etc/inittab

# --- 3. udev: custom service, limited coldplug (prevents coldplugging Android hardware) ---
cat > /etc/init.d/ds-udev << 'EOT'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          udev ds-udev
# Required-Start:
# Required-Stop:
# Default-Start:     S
# Default-Stop:      0 6
# Short-Description: udev for Droidspaces (limited coldplug)
### END INIT INFO

. /lib/lsb/init-functions

find_udevd() {
    for p in /sbin/udevd /usr/sbin/udevd /lib/udev/udevd /usr/lib/udev/udevd /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

hw_access() {
    grep -q '^enable_hw_access=1$' /run/droidspaces/container.config 2>/dev/null
}

host_net() {
    grep -q '^net_mode=host$' /run/droidspaces/container.config 2>/dev/null
}

case "$1" in
    start)
        if host_net; then
            log_action_msg "Host network mode, skipping udev to leave host networking alone"
            exit 0
        fi
        if ! hw_access; then
            log_action_msg "Hardware access is off, skipping udev"
            exit 0
        fi
        UDEVD=$(find_udevd) || {
            log_failure_msg "udevd not found"
            exit 1
        }
        log_daemon_msg "Starting udevd"
        start-stop-daemon --start --quiet --exec "$UDEVD" -- --daemon
        log_end_msg $? || exit $?

        log_action_msg "Coldplugging (usb, block, input, tty, net)"
        udevadm trigger --action=add --subsystem-match=usb --subsystem-match=block \
            --subsystem-match=input --subsystem-match=tty --subsystem-match=net >/dev/null 2>&1 || true
        ;;
    stop)
        log_daemon_msg "Stopping udevd"
        udevadm control --exit >/dev/null 2>&1 || true
        log_end_msg 0
        ;;
    restart|force-reload)
        $0 stop
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|force-reload}"
        exit 2
        ;;
esac
EOT
chmod +x /etc/init.d/ds-udev

# --- 4. DHCP: only in modes that have their own network (skip host and none) ---
cat > /etc/init.d/ds-dhcp << 'EOT'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          ds-dhcp
# Required-Start:    $network
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: dhcpcd for Droidspaces containers
### END INIT INFO

. /lib/lsb/init-functions

netmode_ok() {
    grep -q '^net_mode=' /run/droidspaces/container.config 2>/dev/null && \
        ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config
}

case "$1" in
    start)
        if ! netmode_ok; then
            log_action_msg "net_mode is host/none or unset, skipping DHCP"
            exit 0
        fi
        log_daemon_msg "Starting dhcpcd"
        /usr/sbin/dhcpcd -q --nodev
        log_end_msg $?
        ;;
    stop)
        if ! netmode_ok; then
            log_action_msg "net_mode is host/none or unset, skipping DHCP stop"
            exit 0
        fi
        log_daemon_msg "Stopping dhcpcd"
        /usr/sbin/dhcpcd -x >/dev/null 2>&1 || true
        log_end_msg 0
        ;;
    restart|force-reload)
        $0 stop
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|force-reload}"
        exit 2
        ;;
esac
EOT
chmod +x /etc/init.d/ds-dhcp

# --- 5. Enable essential services ---
# Disable stock udev / eudev so Android hardware/network interfaces are not coldplugged blindly
update-rc.d -f udev remove >/dev/null 2>&1 || true
update-rc.d -f udev-trigger remove >/dev/null 2>&1 || true
update-rc.d -f eudev remove >/dev/null 2>&1 || true
update-rc.d -f eudev-trigger remove >/dev/null 2>&1 || true

# udev is not used in a container; coldplugging Android hardware is unsafe.
update-rc.d -f ds-udev remove >/dev/null 2>&1 || true
update-rc.d dbus defaults >/dev/null 2>&1 || true
update-rc.d ssh defaults >/dev/null 2>&1 || true
update-rc.d ds-dhcp defaults >/dev/null 2>&1 || true

# Configure logrotate for Android
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# Copy binfmt script (SysV init script is generated below instead of a systemd unit)
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
    cat > /etc/init.d/qemu-binfmt-register << 'EOT' && \
    chmod +x /etc/init.d/qemu-binfmt-register && \
    update-rc.d qemu-binfmt-register defaults >/dev/null 2>&1 || true
#!/bin/sh
### BEGIN INIT INFO
# Provides:          qemu-binfmt-register
# Required-Start:    $local_fs
# Required-Stop:
# Default-Start:     2 3 4 5
# Default-Stop:
# Short-Description: Register qemu-user binfmt handlers
### END INIT INFO

. /lib/lsb/init-functions

case "$1" in
    start)
        log_daemon_msg "Registering qemu binfmt handlers"
        /usr/local/bin/qemu-binfmt-register.sh
        log_end_msg $?
        ;;
    stop|restart|force-reload|status)
        exit 0
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|force-reload|status}"
        exit 2
        ;;
esac
EOT

# Purge and reinstall qemu and binfmt in the exact order specified
RUN apt-get purge -y qemu-* binfmt-support || true && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    # Remove any leftover config files
    rm -rf /var/lib/binfmts/* && \
    rm -rf /etc/binfmt.d/* && \
    rm -rf /usr/lib/binfmt.d/qemu-* && \
    # Update package lists
    apt-get update && \
    # Install ONLY these packages (in this specific order)
    apt-get install -y qemu-user-static && \
    apt-get install -y binfmt-support

# Final cleanup of APT cache
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Devuan GNU/Linux 6 (Excalibur) - Minimal (sysvinit)" \
      droidspaces.distro="Devuan" \
      droidspaces.description="Minimal Devuan 6 rootfs with sysvinit and basic packages." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
