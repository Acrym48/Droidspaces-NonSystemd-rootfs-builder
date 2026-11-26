# Dockerfile (Minimal, OpenRC)
# Stage 1: Build and customize the rootfs for development (Minimal - Devuan 6 Excalibur, OpenRC)
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
    # Init: sysvinit-core provides /sbin/init, OpenRC manages services
    sysvinit-core \
    openrc \
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
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Remove default user if it exists
    deluser --remove-home debian || true

# Fix DHCP in the container (dhcpcd instead of systemd-networkd)
RUN printf '\n# Droidspaces: only manage ethernet-like interfaces\nallowinterfaces eth*\n' >> /etc/dhcpcd.conf

# Apply Android compatibility fixes (OpenRC and udev)
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

# --- 2. OpenRC / sysvinit fixes ---
# Container mode: skip hwclock, devfs, swap, etc. and don't touch cgroups
cat >> /etc/rc.conf << 'EOT'

# Droidspaces
rc_sys="lxc"
rc_controller_cgroups="NO"
rc_depend_strict="NO"
EOT

# No VT gettys in a container: drop tty1-6, use the console only
sed -i 's|^\([1-6]:.*getty.*\)$|#\1|' /etc/inittab
grep -q '^c0:' /etc/inittab || echo 'c0:12345:respawn:/sbin/agetty --noclear console 115200 linux' >> /etc/inittab

# Ignore ctrl-alt-del and power events (power button on Android must not reboot the container)
sed -i 's|^\(ca:.*ctrlaltdel.*\)$|#\1|; s|^\(pf:.*\)$|#\1|; s|^\(pr:.*\)$|#\1|' /etc/inittab

# Droidspaces finds /sbin/openrc and treats this container as OpenRC, so a stop
# sends SIGPWR. sysvinit only acts on SIGPWR through the inittab "pf" action,
# which is disabled above, so the stop waits 15 seconds and then SIGKILLs.
# Map it to runlevel 0 instead to get a clean OpenRC shutdown.
grep -q '^pf:' /etc/inittab || echo 'pf::powerwait:/sbin/telinit 0' >> /etc/inittab

# --- 3. udev: custom service, limited coldplug (prevents coldplugging Android hardware) ---
cat > /etc/init.d/ds-udev << 'EOT'
#!/sbin/openrc-run
description="udev for Droidspaces (limited coldplug)"

depend() {
    provide udev
}

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

start() {
    # udev is only useful when hardware access is on. In host network mode it
    # must not run at all: the container shares the phone's network namespace,
    # and udev rules can rename/reconfigure the phone's Wi-Fi and mobile
    # interfaces even without an explicit coldplug.
    if host_net; then
        einfo "Host network mode, skipping udev to leave host networking alone"
        return 0
    fi
    if ! hw_access; then
        einfo "Hardware access is off, skipping udev"
        return 0
    fi
    UDEVD=$(find_udevd) || { eerror "udevd not found"; return 1; }
    ebegin "Starting udevd"
    start-stop-daemon --start --exec "$UDEVD" -- --daemon
    eend $? || return $?
    ebegin "Coldplugging (usb, block, input, tty, net)"
    udevadm trigger --action=add --subsystem-match=usb --subsystem-match=block \
        --subsystem-match=input --subsystem-match=tty --subsystem-match=net
    eend 0
}

stop() {
    ebegin "Stopping udevd"
    udevadm control --exit >/dev/null 2>&1
    eend 0
}
EOT
chmod +x /etc/init.d/ds-udev

# --- 4. DHCP: only in modes that have their own network (skip host and none) ---
# Prevents cellular network breakage when running in host network mode
cat > /etc/init.d/ds-dhcp << 'EOT'
#!/sbin/openrc-run
description="dhcpcd for Droidspaces containers"

depend() {
    # Devuan/OpenRC has no localmount script (Debian uses mountall.sh), and
    # an unresolvable "need localmount" silently prevents this service from
    # ever starting - which leaves NAT containers without a DHCP client.
    after bootmisc
    provide net
}

netmode_ok() {
    grep -q '^net_mode=' /run/droidspaces/container.config 2>/dev/null && \
        ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config
}

start() {
    if ! netmode_ok; then
        einfo "net_mode is host/none or unset, skipping DHCP"
        return 0
    fi
    ebegin "Starting dhcpcd"
    # --nodev: udev never announces an interface created in a container's own
    # network namespace, and dhcpcd would wait on it forever.
    /usr/sbin/dhcpcd -q --nodev
    eend $?
}

stop() {
    if ! netmode_ok; then
        einfo "net_mode is host/none or unset, skipping DHCP stop"
        return 0
    fi
    ebegin "Stopping dhcpcd"
    /usr/sbin/dhcpcd -x >/dev/null 2>&1
    eend 0
}
EOT
chmod +x /etc/init.d/ds-dhcp

# --- 5. Enable essential services ---
# Replace the packaged udev with ds-udev. Devuan enables the service as
# "eudev" (the "udev" package is a wrapper), so both names must go: leaving
# eudev in sysinit lets the stock service coldplug every Android device,
# including the host's network interfaces when net_mode=host.
rc-update del udev sysinit 2>/dev/null || true
rc-update del udev boot 2>/dev/null || true
rc-update del udev-trigger sysinit 2>/dev/null || true
rc-update del eudev sysinit 2>/dev/null || true
rc-update del eudev boot 2>/dev/null || true
rc-update del eudev-trigger sysinit 2>/dev/null || true
rc-update add ds-udev sysinit
rc-update add dbus default || true
rc-update add ssh default || true
rc-update add ds-dhcp default

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

# Copy binfmt script (OpenRC service is generated below instead of a systemd unit)
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
    cat > /etc/init.d/qemu-binfmt-register << 'EOT' && \
    chmod +x /etc/init.d/qemu-binfmt-register && \
    rc-update add qemu-binfmt-register default
#!/sbin/openrc-run
description="Register qemu-user binfmt handlers"

depend() {
    need localmount
    after bootmisc
}

start() {
    ebegin "Registering qemu binfmt handlers"
    /usr/local/bin/qemu-binfmt-register.sh
    eend $?
}
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
LABEL droidspaces.name="Devuan GNU/Linux 6 (Excalibur) - Minimal (OpenRC)" \
      droidspaces.distro="Devuan" \
      droidspaces.description="Minimal Devuan 6 rootfs with OpenRC and basic packages." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
