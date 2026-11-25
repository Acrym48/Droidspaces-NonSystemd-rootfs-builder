# Alpine Linux Desktop - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: OpenRC
# Desktop: XFCE4

# --------------------------------------------------
# Build and customize the rootfs (Alpine 3.23)
# --------------------------------------------------
FROM alpine:3.23 AS customizer

ENV DEBIAN_FRONTEND=noninteractive

# Update base system
RUN apk update && apk upgrade

# Copy custom scripts
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Install core + XFCE4 desktop
RUN apk add --no-cache \
    # Core utilities
    bash \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    tzdata \
    bash-completion \
    shadow \
    sudo \
    # Networking & SSH
    openssh \
    net-tools \
    iptables-legacy \
    iputils \
    iproute2 \
    bind-tools \
    # System monitoring
    procps \
    htop \
    # DHCP client + openrc
    dhcpcd \
    openrc \
    busybox-extras \
    dbus \
    dbus-x11 \
    elogind \
    polkit \
    # XFCE4 desktop
    xfce4 \
    xfce4-terminal \
    xfce4-session \
    xfwm4 \
    xfconf \
    thunar \
    thunar-volman \
    thunar-archive-plugin \
    mousepad \
    ristretto \
    xarchiver \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-clipman-plugin \
    xfce4-notifyd \
    tumbler \
    gvfs \
    adwaita-icon-theme \
    hicolor-icon-theme \
    font-dejavu \
    font-liberation \
    font-noto \
    pulseaudio \
    pulseaudio-utils \
    pavucontrol \
    firefox \
    # Xorg
    xorg-server \
    xinit \
    xset \
    xrandr \
    xrdb \
    xsetroot \
    xprop \
    xdpyinfo \
    xwininfo \
    at-spi2-core \
    # Development (optional)
    git \
    nano

# Configure iptables-legacy (MANDATORY for Android compatibility)
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true

# Configure locales, environment, SSH
RUN mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Android compatibility fixes
RUN <<EOF_RUN
# Android network group setup
grep -q '^aid_inet:' /etc/group    || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# Root permissions for Android hardware access
usermod -a -G aid_inet,aid_net_raw,input,video,tty root || true

# _apt needs aid_inet (Alpine uses _apt? usually not; skip if absent)
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

# Tell OpenRC it's in an LXC-style container.
sed -i 's/^#\?rc_sys=.*/rc_sys="lxc"/' /etc/rc.conf

# Remove "dev" dependency from machine-id init script to prevent boot warnings
if [ -f /etc/init.d/machine-id ]; then
    sed -i 's/need root dev/need root/' /etc/init.d/machine-id
fi

# Fix inittab: remove tty1-6, add console getty
sed -i '/^tty[1-6]::/d' /etc/inittab
grep -q 'console::respawn' /etc/inittab || \
    echo 'console::respawn:/sbin/getty 38400 console' >> /etc/inittab
grep -q '^console$' /etc/securetty || echo 'console' >> /etc/securetty

# Wire up dhcpcd and sshd to default runlevel
mkdir -p /etc/runlevels/default
ln -sf /etc/init.d/dhcpcd /etc/runlevels/default/dhcpcd
ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd

# Replace dhcpcd init script to stay out of host and none network modes
cat > /etc/init.d/dhcpcd << 'INITEOF'
#!/sbin/openrc-run

description="DHCP Client Daemon"

command="/sbin/dhcpcd"
command_args="-q -B --nodev ${command_args:-}"
command_background="true"
pidfile="/run/dhcpcd/pid"

depend() {
	provide net
	need localmount
	use logger network
	after bootmisc modules
	before dns
}

start_pre() {
	if ! grep -qs '^net_mode=' /run/droidspaces/container.config ||
		grep -qsE '^net_mode=(host|none)$' /run/droidspaces/container.config; then
		einfo "Skipping dhcpcd: host or none network mode"
		return 1
	fi
	checkpath -d /run/dhcpcd
}
INITEOF
chmod +x /etc/init.d/dhcpcd

# Additionally whitelist only container veth interfaces (eth*) in dhcpcd.conf
if [ -f /etc/dhcpcd.conf ]; then
    grep -qx 'allowinterfaces eth*' /etc/dhcpcd.conf || echo "allowinterfaces eth*" >> /etc/dhcpcd.conf
fi

# Configure elogind for Android (disable power key handling)
mkdir -p /etc/elogind/logind.conf.d
cat > /etc/elogind/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

# Mark fixes as completed
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# XFCE autostart OpenRC service for Anland/X11
RUN <<EOF_RUN
set -eux
cat > /etc/init.d/xfce-autostart << 'SERVICE'
#!/sbin/openrc-run
description="XFCE autostart"

depend() {
    need dhcpcd
}

start() {
    cfg=/run/droidspaces/container.config
    if ! grep -qE '^enable_(termux_)?x11=1' "$cfg" 2>/dev/null; then
        einfo "X11 not enabled, skipping XFCE"
        return 0
    fi
    while [ ! -S /tmp/.X11-unix/X5 ]; do sleep 1; done
    ebegin "Starting XFCE"
    start-stop-daemon --start --background --exec /usr/local/bin/xfce-start
    eend $?
}
stop() {
    start-stop-daemon --stop --exec /usr/local/bin/xfce-start 2>/dev/null
    eend 0
}
SERVICE
chmod +x /etc/init.d/xfce-autostart
ln -sf /etc/init.d/xfce-autostart /etc/runlevels/default/xfce-autostart
EOF_RUN

# Install xfce-start and xfwm4.xml
COPY scripts/xfce-start /usr/local/bin/xfce-start
COPY scripts/xfwm4.xml /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
COPY scripts/xfwm4.xml /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
RUN chmod +x /usr/local/bin/xfce-start && \
    mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml && \
    mkdir -p /root/.config/xfce4/xfconf/xfce-perchannel-xml && \
    if [ -f /usr/share/xfwm4/defaults ]; then \
        if grep -q '^vblank_mode=' /usr/share/xfwm4/defaults; then \
            sed -i 's/^vblank_mode=.*/vblank_mode=off/' /usr/share/xfwm4/defaults; \
        else \
            echo 'vblank_mode=off' >> /usr/share/xfwm4/defaults; \
        fi; \
    fi

# Configure bashrc aliases
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Update icon and font caches
RUN fc-cache -fv 2>/dev/null || true

# Final cleanup
RUN rm -rf /var/cache/apk/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export
LABEL droidspaces.name="Alpine Linux - Desktop (OpenRC)" \
      droidspaces.distro="Alpine" \
      droidspaces.description="Alpine Linux ARM64 with musl libc, native OpenRC init, and XFCE4 desktop. CLI + GUI." \
      droidspaces.author="Acrym48"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /