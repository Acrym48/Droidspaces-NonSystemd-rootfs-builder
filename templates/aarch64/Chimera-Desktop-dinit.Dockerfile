# Chimera Linux Desktop - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: dinit
# Desktop: XFCE4

# --------------------------------------------------
# Bootstrap official Chimera Linux rootfs
# --------------------------------------------------
FROM alpine:3.23 AS bootstrap

RUN apk add --no-cache curl tar

WORKDIR /rootfs

RUN curl -fL \
    https://repo.chimera-linux.org/live/latest/chimera-linux-aarch64-ROOTFS-20261103-bootstrap.tar.gz \
    -o /tmp/chimera-rootfs.tar.gz && \
    tar -xzf /tmp/chimera-rootfs.tar.gz -C /rootfs && \
    rm -f /tmp/chimera-rootfs.tar.gz


# --------------------------------------------------
# Base rootfs
# --------------------------------------------------
FROM scratch AS base

COPY --from=bootstrap /rootfs /


# --------------------------------------------------
# Customize Chimera Linux
# --------------------------------------------------
FROM base AS customizer

# Repositories: main + user (XFCE lives in user).
RUN printf '%s\n' \
    'https://repo.chimera-linux.org/current/main' \
    'https://repo.chimera-linux.org/current/user' \
    > /etc/apk/repositories

# Minimal CLI system + XFCE4 desktop.
RUN apk update && apk add --no-progress \
    base-files \
    chimerautils \
    bash \
    bash-completion \
    ca-certificates \
    curl \
    wget \
    nano \
    htop \
    shadow \
    tzdata \
    openssh \
    iproute2 \
    iputils \
    procps \
    dhcpcd \
    dinit \
    dinit-chimera \
    dinit-chimera-device-none \
    turnstile \
    iptables-legacy \
    file \
    libarchive-progs \
    dbus \
    dbus-x11 \
    xserver-xorg-minimal \
    xinit \
    xset \
    xrandr \
    xfce4 \
    xfce4-terminal \
    xfce4-session \
    xfwm4 \
    xfconf \
    thunar \
    thunar-volman \
    mousepad \
    ristretto \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-clipman-plugin \
    xfce4-notifyd \
    tumbler \
    gvfs \
    fonts-dejavu \
    fonts-liberation \
    fonts-noto \
    pipewire \
    wireplumber \
    pavucontrol \
    firefox

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty root

# Droidspaces init detection surgery (same as minimal).
RUN set -eux; \
    mv /usr/bin/init /usr/bin/dinit-init; \
    ln -s dinit-init /usr/bin/init; \
    sed -i.bak 's|exec "/usr/bin/dinit"|exec "/usr/bin/dinit" --container|' /usr/bin/dinit-init; \
    rm -f /usr/bin/dinit-init.bak; \
    grep -qF -e '--container' /usr/bin/dinit-init; \
    test -L /usr/bin/init; \
    test "$(readlink /usr/bin/init)" = dinit-init

# Basic configuration
RUN set -eux; \
    echo "chimera-droidspaces-desktop" > /etc/hostname; \
    mkdir -p /run/sshd /etc/dinit /etc/dinit.d/boot.d /usr/lib/droidspaces

# Tell dinit this is a container.
RUN printf '%s\n' 'container=1' 'export container' > /etc/dinit/init

# dhcpcd dinit service.
RUN <<EOF_RUN
set -eux
cat > /usr/lib/droidspaces/ds-dhcp <<'SCRIPT'
#!/bin/sh
cfg=/run/droidspaces/container.config
if grep -q '^net_mode=' "$cfg" 2>/dev/null && ! grep -qE '^net_mode=(host|none)$' "$cfg"; then
    if ! grep -qx 'nodev' /etc/dhcpcd.conf 2>/dev/null; then
        echo 'nodev' >> /etc/dhcpcd.conf
    fi
    exec dhcpcd -B -M -j /var/log/dhcpcd-service.log
fi
exec sleep 2147483647
SCRIPT
chmod +x /usr/lib/droidspaces/ds-dhcp

cat > /etc/dinit.d/ds-dhcp <<'SERVICE'
type = process
command = /usr/lib/droidspaces/ds-dhcp
logfile = /var/log/ds-dhcp.log
before: network.target
depends-on: pre-network.target
SERVICE

ln -sf ../ds-dhcp /etc/dinit.d/boot.d/ds-dhcp
EOF_RUN

# XFCE autostart dinit service for Anland/X11.
RUN <<EOF_RUN
set -eux
cat > /etc/dinit.d/xfce-autostart <<'SERVICE'
type = process
command = /usr/local/bin/xfce-start
logfile = /var/log/xfce-autostart.log
depends-on: local.target
depends-on: network.target
SERVICE

# Condition: only run if X11 is enabled and socket exists.
cat > /usr/local/bin/xfce-autostart-wrapper <<'SCRIPT'
#!/bin/sh
cfg=/run/droidspaces/container.config
if ! grep -qE '^enable_(termux_)?x11=1' "$cfg" 2>/dev/null; then
    exec sleep 2147483647
fi
while [ ! -S /tmp/.X11-unix/X5 ]; do sleep 1; done
exec /usr/local/bin/xfce-start
SCRIPT
chmod +x /usr/local/bin/xfce-autostart-wrapper
sed -i.bak 's|command = /usr/local/bin/xfce-start|command = /usr/local/bin/xfce-autostart-wrapper|' /etc/dinit.d/xfce-autostart
rm -f /etc/dinit.d/xfce-autostart.bak
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
            sed -i.bak 's/^vblank_mode=.*/vblank_mode=off/' /usr/share/xfwm4/defaults; \
            rm -f /usr/share/xfwm4/defaults.bak; \
        else \
            echo 'vblank_mode=off' >> /usr/share/xfwm4/defaults; \
        fi; \
    fi

# Configure bashrc aliases
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /etc/profile.d/ds-aliases.sh

# Update icon and font caches
RUN fc-cache -fv 2>/dev/null || true

# Clean package cache
RUN apk cache clean && rm -rf /var/cache/apk/* /tmp/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Chimera Linux - Desktop (dinit)" \
      droidspaces.distro="Chimera Linux" \
      droidspaces.description="Chimera Linux ARM64 with musl libc, native dinit init, and XFCE4 desktop. CLI + GUI." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /