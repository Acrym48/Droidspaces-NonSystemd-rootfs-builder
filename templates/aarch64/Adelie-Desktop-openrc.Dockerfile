# Adélie Linux Desktop - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: sysvinit (OpenRC services)
# Desktop: XFCE4

# --------------------------------------------------
# Bootstrap official Adélie Linux rootfs
# --------------------------------------------------
FROM alpine:3.23 AS bootstrap

RUN apk add --no-cache curl tar xz

WORKDIR /rootfs

RUN curl -fL \
    https://adelielinux.nic.cz/adelie/1.0-beta6/iso/adelie-rootfs-mini-aarch64-1.0-beta6-20241223.txz \
    -o /tmp/adelie-rootfs.txz && \
    tar -xJpf /tmp/adelie-rootfs.txz -C /rootfs && \
    rm -f /tmp/adelie-rootfs.txz


# --------------------------------------------------
# Base rootfs
# --------------------------------------------------
FROM scratch AS base

COPY --from=bootstrap /rootfs /


# --------------------------------------------------
# Customize Adélie Linux
# --------------------------------------------------
FROM base AS customizer

# Repositories: system + user (XFCE lives in user).
RUN printf '%s\n' \
    'https://adelielinux.nic.cz/adelie/current/system' \
    'https://adelielinux.nic.cz/adelie/current/user' \
    > /etc/apk/repositories

# Core + XFCE4 desktop.
RUN apk update && apk add --no-progress \
    bash \
    bash-completion \
    curl \
    wget \
    nano \
    htop \
    openssh \
    openssh-openrc \
    iproute2 \
    iputils \
    file \
    libarchive-tools \
    dhcpcd \
    openrc \
    sysvinit \
    tzdata \
    dbus \
    dbus-x11 \
    xfce-desktop \
    xfce4-terminal \
    xfce4-session \
    xfce4-settings \
    xfwm4 \
    xfconf \
    thunar \
    thunar-volman \
    thunar-archive-plugin \
    mousepad \
    ristretto \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-clipman-plugin \
    xfce4-notifyd \
    tumbler \
    gvfs \
    ttf-dejavu \
    ttf-liberation \
    ttf-noto \
    pulseaudio \
    pulseaudio-utils \
    pavucontrol \
    firefox-esr \
    xorg-server \
    xinit \
    xset \
    xrandr

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty root

# Basic configuration
RUN set -eux; \
    echo "adelie-droidspaces-desktop" > /etc/hostname; \
    mkdir -p /run/sshd /etc/init.d /usr/lib/droidspaces; \
    # Droidspaces enters containers with `su -l <user>`, which uses the PAM
    # service "su-l". Adélie ships only "su", so create the missing alias.
    cp /etc/pam.d/su /etc/pam.d/su-l; \
    # dash is the default /bin/sh; use bash as root's login shell.
    chsh -s /bin/bash root 2>/dev/null || usermod -s /bin/bash root

# Droidspaces detection surgery.
RUN set -eux; \
    if [ -f /sbin/openrc ]; then mv /sbin/openrc /sbin/openrc.bin; fi; \
    if [ -f /bin/s6-svscan ]; then mv /bin/s6-svscan /bin/s6-svscan.bin; fi; \
    test ! -e /sbin/openrc; \
    test ! -e /bin/s6-svscan

# Drive OpenRC through /sbin/rc instead of /sbin/openrc.
RUN set -eux; \
    sed -i.bak 's|/sbin/openrc |/sbin/rc |g' /etc/inittab; \
    sed -i.bak -e '/^s6:/d' -e '/^s6n:/d' /etc/inittab; \
    rm -f /etc/inittab.bak; \
    grep -q '/sbin/rc' /etc/inittab

# dhcpcd OpenRC service.
RUN <<EOF_RUN
set -eux
cat > /usr/lib/droidspaces/ds-dhcp <<'SCRIPT'
#!/bin/sh
cfg=/run/droidspaces/container.config
if grep -q '^net_mode=' "$cfg" 2>/dev/null && ! grep -qE '^net_mode=(host|none)$' "$cfg"; then
    if ! grep -qx 'nodev' /etc/dhcpcd.conf 2>/dev/null; then
        echo 'nodev' >> /etc/dhcpcd.conf
    fi
    exec /sbin/dhcpcd -B -M -j /var/log/dhcpcd-service.log
fi
exec sleep 2147483647
SCRIPT
chmod +x /usr/lib/droidspaces/ds-dhcp

cat > /etc/init.d/ds-dhcp <<'SERVICE'
#!/sbin/openrc-run
description="Droidspaces DHCP"
depend() {
    need loopback
    before net
}
start() {
    cfg=/run/droidspaces/container.config
    if grep -q '^net_mode=' "$cfg" 2>/dev/null && ! grep -qE '^net_mode=(host|none)$' "$cfg"; then
        ebegin "Starting dhcpcd"
        start-stop-daemon --start --exec /sbin/dhcpcd -- -B -M -j /var/log/dhcpcd-service.log
        eend $?
    else
        ebegin "Skipping dhcpcd (host/none network mode)"
        eend 0
    fi
}
stop() {
    start-stop-daemon --stop --exec /sbin/dhcpcd 2>/dev/null
    eend 0
}
SERVICE
chmod +x /etc/init.d/ds-dhcp
rc-update add ds-dhcp default

# XFCE autostart OpenRC service for Anland/X11.
cat > /etc/init.d/xfce-autostart <<'SERVICE'
#!/sbin/openrc-run
description="XFCE autostart"
depend() {
    need ds-dhcp
}
start() {
    cfg=/run/droidspaces/container.config
    if ! grep -qE '^enable_(termux_)?x11=1' "$cfg" 2>/dev/null; then
        ebegin "X11 not enabled, skipping XFCE"
        eend 0
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
rc-update add xfce-autostart default
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

# Clean package cache
RUN apk cache clean 2>/dev/null || true; rm -rf /var/cache/apk/* /tmp/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Adélie Linux - Desktop (OpenRC)" \
      droidspaces.distro="Adélie Linux" \
      droidspaces.description="Adélie Linux ARM64 with musl libc, native OpenRC init, and XFCE4 desktop. CLI + GUI." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /