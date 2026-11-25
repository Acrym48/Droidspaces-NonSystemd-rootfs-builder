# Void Linux Desktop - DroidSpaces
# Architecture: aarch64
# Libc: glibc
# Init: runit
# Desktop: XFCE4

# --------------------------------------------------
# Bootstrap official Void Linux rootfs
# --------------------------------------------------
FROM alpine:3.23 AS bootstrap

RUN apk add --no-cache curl xz tar

WORKDIR /rootfs

RUN curl -fL \
    https://repo-default.voidlinux.org/live/current/void-aarch64-ROOTFS-20250202.tar.xz \
    -o /tmp/void-rootfs.tar.xz && \
    tar -xJpf /tmp/void-rootfs.tar.xz -C /rootfs && \
    rm -f /tmp/void-rootfs.tar.xz


# --------------------------------------------------
# Base rootfs
# --------------------------------------------------
FROM scratch AS base

COPY --from=bootstrap /rootfs /


# --------------------------------------------------
# Customize Void Linux
# --------------------------------------------------
FROM base AS customizer

# Update XBPS and install base system
RUN xbps-install -S && \
    xbps-install -u xbps -y && \
    xbps-install -Syu && \
    xbps-install -y base-system

# Install CLI toolset
RUN xbps-install -y \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    wget \
    nano \
    htop \
    sudo \
    shadow \
    tzdata \
    openssh \
    iproute2 \
    iputils \
    procps-ng \
    dhcpcd \
    dbus \
    elogind \
    polkit

# Install XFCE4 desktop environment
RUN xbps-install -y \
    xfce4 \
    xfce4-terminal \
    xfce4-session \
    xfwm4 \
    xfconf \
    Thunar \
    thunar-volman \
    thunar-archive-plugin \
    thunar-media-tags-plugin \
    mousepad \
    ristretto \
    xarchiver \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-clipman-plugin \
    xfce4-notifyd \
    xorg-minimal \
    xinit \
    xrandr xset xrdb xsetroot \
    xprop xdpyinfo xwininfo \
    dbus-x11 \
    at-spi2-core \
    tumbler \
    gvfs \
    gvfs-mtp \
    gvfs-smb \
    adwaita-icon-theme \
    hicolor-icon-theme \
    dejavu-fonts-ttf \
    liberation-fonts-ttf \
    pulseaudio \
    pulseaudio-utils \
    pavucontrol \
    firefox

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || \
        groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || \
        groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || \
        groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty root

# Basic configuration
RUN set -eux; \
    echo "void-droidspaces-desktop" > /etc/hostname; \
    mkdir -p /run/sshd /etc/profile.d /usr/lib/droidspaces

# Configure elogind for Android (disable power key handling)
RUN mkdir -p /etc/elogind/logind.conf.d && \
    cat > /etc/elogind/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

# dhcpcd runit service: run it only when the container has its own network.
RUN <<EOF_RUN
set -eux
mkdir -p /etc/sv/ds-dhcp
cat > /etc/sv/ds-dhcp/run <<'SCRIPT'
#!/bin/sh
cfg=/run/droidspaces/container.config
if grep -q '^net_mode=' "$cfg" 2>/dev/null && ! grep -qE '^net_mode=(host|none)$' "$cfg"; then
    if ! grep -qx 'nodev' /etc/dhcpcd.conf; then
       echo 'nodev' >> /etc/dhcpcd.conf
    fi
    exec dhcpcd -B
fi
# host/none network mode: stay idle so runsv does not respawn in a loop
exec sleep infinity
SCRIPT
chmod +x /etc/sv/ds-dhcp/run
ln -sf /etc/sv/ds-dhcp /etc/runit/runsvdir/default/ds-dhcp
EOF_RUN

# XFCE autostart service (runit) for Anland/X11
RUN <<EOF_RUN
set -eux
mkdir -p /etc/sv/xfce-autostart
cat > /etc/sv/xfce-autostart/run <<'SCRIPT'
#!/bin/sh
# Wait for X11 socket
while [ ! -S /tmp/.X11-unix/X5 ]; do sleep 1; done
# Check if X11 is enabled
cfg=/run/droidspaces/container.config
if grep -qE '^enable_(termux_)?x11=1' "$cfg" 2>/dev/null; then
    exec /usr/local/bin/xfce-start
fi
# Not enabled: idle
exec sleep infinity
SCRIPT
chmod +x /etc/sv/xfce-autostart/run
ln -sf /etc/sv/xfce-autostart /etc/runit/runsvdir/default/xfce-autostart
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
RUN gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true && \
    fc-cache -fv 2>/dev/null || true

# Clean package cache
RUN xbps-remove -O && \
    rm -rf /var/cache/xbps/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Void Linux - Desktop (runit)" \
      droidspaces.distro="Void Linux" \
      droidspaces.description="Void Linux ARM64 with glibc, native runit init, and XFCE4 desktop. CLI + GUI." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /