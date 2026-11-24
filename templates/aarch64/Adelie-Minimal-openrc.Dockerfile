# Adélie Linux Minimal - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: sysvinit (OpenRC services)

# --------------------------------------------------
# Bootstrap official Adélie Linux rootfs
# --------------------------------------------------
FROM alpine:3.23 AS bootstrap

RUN apk add --no-cache curl tar xz

WORKDIR /rootfs

RUN curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 \
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

# The mini rootfs points at distfiles.adelielinux.org, which is not reachable
# from some build environments (e.g. GitHub Actions). Use the nic.cz mirror.
RUN printf '%s\n' \
    'https://adelielinux.nic.cz/adelie/current/system' \
    'https://adelielinux.nic.cz/adelie/current/user' \
    > /etc/apk/repositories

# The mini rootfs already ships the Adélie repositories.
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
    tzdata

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty root

# Basic configuration
RUN set -eux; \
    echo "adelie-droidspaces" > /etc/hostname; \
    mkdir -p /run/sshd /etc/init.d /usr/lib/droidspaces; \
    # Droidspaces enters containers with `su -l <user>`, which uses the PAM
    # service "su-l". Adélie ships only "su", so create the missing alias.
    cp /etc/pam.d/su /etc/pam.d/su-l; \
    # dash (the default /bin/sh) mishandles the PTY process group that
    # Droidspaces sets up and fails to exit on `exit`. Use bash as root's
    # login shell instead.
    chsh -s /bin/bash root 2>/dev/null || usermod -s /bin/bash root

# Droidspaces detects /sbin/openrc and /bin/s6-svscan before /sbin/init and
# would otherwise classify the container as OpenRC (SIGPWR) or s6 (SIGUSR2).
# sysvinit ignores those signals, so hide the two detection targets and let
# /sbin/init (real sysvinit) be chosen: Droidspaces then writes a telinit
# runlevel-0 request to /run/initctl, which sysvinit actually acts on.
# OpenRC is still driven through /sbin/rc (the same binary, different name).
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

# dhcpcd dinit-style service for OpenRC: run it only when the container has
# its own network. In host/none mode dhcpcd would reconfigure the phone.
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
# host/none network mode: stay idle so OpenRC does not restart in a loop
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
EOF_RUN

# Clean package cache
RUN apk cache clean 2>/dev/null || true; rm -rf /var/cache/apk/* /tmp/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Adélie Linux - Minimal (OpenRC)" \
      droidspaces.distro="Adélie Linux" \
      droidspaces.description="Minimal Adélie Linux ARM64 with musl libc and native OpenRC init. CLI only." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /