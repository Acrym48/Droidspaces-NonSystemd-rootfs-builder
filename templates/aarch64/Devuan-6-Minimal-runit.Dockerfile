# Dockerfile (Minimal, runit)
# Stage 1: Build and customize the rootfs for development (Minimal - Devuan 6 Excalibur, runit)
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
    # Init: runit + runit-init (fallback to runit if runit-init is a separate/virtual package)
    runit \
    runit-init \
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

# Apply Android compatibility fixes (runit)
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

# --- 2. runit stage scripts & service directory ---
mkdir -p /etc/runit /etc/sv /etc/service

# Stage 1: one-time container initialization
cat > /etc/runit/1 << 'EOT'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mkdir -p /run /run/lock /var/log /var/run/sshd /run/sshd
chmod 1777 /run/lock

# Load extra kernel modules if configured
if [ -f /etc/modules ]; then
    while IFS= read -r mod || [ -n "$mod" ]; do
        case "$mod" in
            ''|'#'*) continue ;;
        esac
        modprobe ${mod%% *} >/dev/null 2>&1 || true
    done < /etc/modules
fi
EOT
chmod +x /etc/runit/1

# Stage 2: run supervision tree
cat > /etc/runit/2 << 'EOT'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

exec runsvdir -P /etc/service 'log:........................................................................................................................................................................................................................................................................................................................................................................................................'
EOT
chmod +x /etc/runit/2

# Stage 3: clean shutdown / stop services
cat > /etc/runit/3 << 'EOT'
#!/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ -d /etc/service ]; then
    sv -w10 force-stop /etc/service/* >/dev/null 2>&1 || true
fi
EOT
chmod +x /etc/runit/3

# Ensure /sbin/init points to runit-init if available
if [ -x /sbin/runit-init ] && [ ! -e /sbin/init ]; then
    ln -sf /sbin/runit-init /sbin/init
elif [ -x /lib/runit/runit-init ] && [ ! -e /sbin/init ]; then
    ln -sf /lib/runit/runit-init /sbin/init
fi

# --- 3. udev: custom service, limited coldplug ---
mkdir -p /etc/sv/ds-udev
cat > /etc/sv/ds-udev/run << 'EOT'
#!/bin/sh
exec 2>&1

hw_access() {
    grep -q '^enable_hw_access=1$' /run/droidspaces/container.config 2>/dev/null
}

host_net() {
    grep -q '^net_mode=host$' /run/droidspaces/container.config 2>/dev/null
}

find_udevd() {
    for p in /sbin/udevd /usr/sbin/udevd /lib/udev/udevd /usr/lib/udev/udevd /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    return 1
}

if host_net; then
    echo "Host network mode, skipping udev to leave host networking alone"
    exec sleep infinity
fi

if ! hw_access; then
    echo "Hardware access is off, skipping udev"
    exec sleep infinity
fi

UDEVD=$(find_udevd) || {
    echo "udevd not found" >&2
    exec sleep infinity
}

# Trigger coldplug once daemon is ready
(
    sleep 1
    udevadm trigger --action=add --subsystem-match=usb --subsystem-match=block \
        --subsystem-match=input --subsystem-match=tty --subsystem-match=net >/dev/null 2>&1 || true
) &

exec "$UDEVD"
EOT
chmod +x /etc/sv/ds-udev/run

# --- 4. dbus service ---
mkdir -p /etc/sv/dbus
cat > /etc/sv/dbus/run << 'EOT'
#!/bin/sh
exec 2>&1
mkdir -p /run/dbus
dbus-uuidgen --ensure=/var/lib/dbus/machine-id
exec /usr/bin/dbus-daemon --system --nofork --nopidfile
EOT
chmod +x /etc/sv/dbus/run

# --- 5. sshd service ---
mkdir -p /etc/sv/sshd
cat > /etc/sv/sshd/run << 'EOT'
#!/bin/sh
exec 2>&1
mkdir -p /var/run/sshd /run/sshd
ssh-keygen -A >/dev/null 2>&1 || true
exec /usr/sbin/sshd -D -e
EOT
chmod +x /etc/sv/sshd/run

# --- 6. DHCP: only in modes that have their own network (skip host and none) ---
mkdir -p /etc/sv/ds-dhcp
cat > /etc/sv/ds-dhcp/run << 'EOT'
#!/bin/sh
exec 2>&1

netmode_ok() {
    grep -q '^net_mode=' /run/droidspaces/container.config 2>/dev/null && \
        ! grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config
}

if ! netmode_ok; then
    echo "net_mode is host/none or unset, skipping DHCP"
    exec sleep infinity
fi

# Run dhcpcd in foreground (-B / non-background) so runsv supervises it cleanly
exec /usr/sbin/dhcpcd -B --nodev
EOT
cat > /etc/sv/ds-dhcp/finish << 'EOT'
#!/bin/sh
/usr/sbin/dhcpcd -x >/dev/null 2>&1 || true
EOT
chmod +x /etc/sv/ds-dhcp/run /etc/sv/ds-dhcp/finish

# Enable services via /etc/service symlinks
ln -sfn /etc/sv/ds-udev /etc/service/ds-udev
ln -sfn /etc/sv/dbus /etc/service/dbus
ln -sfn /etc/sv/sshd /etc/service/sshd
ln -sfn /etc/sv/ds-dhcp /etc/service/ds-dhcp

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

# Copy binfmt script (runit service is generated below instead of a systemd unit)
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
RUN mkdir -p /etc/sv/qemu-binfmt-register && \
    chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
    cat > /etc/sv/qemu-binfmt-register/run << 'EOT' && \
    chmod +x /etc/sv/qemu-binfmt-register/run && \
    ln -sfn /etc/sv/qemu-binfmt-register /etc/service/qemu-binfmt-register
#!/bin/sh
exec 2>&1
/usr/local/bin/qemu-binfmt-register.sh
# Oneshot-style keepalive under runsv so runsv does not treat exit 0 as a crash loop
exec sleep infinity
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
LABEL droidspaces.name="Devuan GNU/Linux 6 (Excalibur) - Minimal (runit)" \
      droidspaces.distro="Devuan" \
      droidspaces.description="Minimal Devuan 6 rootfs with runit and basic packages." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
