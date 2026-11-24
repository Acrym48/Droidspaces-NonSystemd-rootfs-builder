# Chimera Linux Minimal - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: dinit

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

# The bootstrap tarball ships apk and the signing keys, but no repository.
RUN printf '%s\n' 'https://repo.chimera-linux.org/current/main' > /etc/apk/repositories

# Minimal CLI system. dinit-chimera-device-none provides the device-manager
# stubs, so dinit does not pull udev into a container that has no hardware
# events to process.
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
    libarchive-progs

# Droidspaces classifies a regular /sbin/init file as sysvinit and then tries
# the initctl FIFO, which Chimera does not have. Expose /sbin/init as a symlink
# to the dinit-chimera wrapper instead: it is then detected as an unknown init
# and stopped with SIGTERM, which dinit actually handles.
#
# --container keeps dinit from trying to halt/reboot the host; it stops the
# services and exits, so the container shuts down gracefully.
RUN set -eux; \
    mv /usr/bin/init /usr/bin/dinit-init; \
    ln -s dinit-init /usr/bin/init; \
    sed -i 's|exec "/usr/bin/dinit"|exec "/usr/bin/dinit" --container|' /usr/bin/dinit-init; \
    grep -q -- '--container' /usr/bin/dinit-init; \
    test -L /usr/bin/init; \
    test "$(readlink /usr/bin/init)" = dinit-init

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty root

# Basic configuration
RUN set -eux; \
    echo "chimera-droidspaces" > /etc/hostname; \
    mkdir -p /run/sshd /etc/dinit /etc/dinit.d/boot.d /usr/lib/droidspaces

# Tell dinit and dinit-chimera's early scripts that this is a container.
# The host mounts /proc, /sys and /dev, so the early mount helpers must stay
# out of the way.
RUN printf '%s\n' 'container=1' 'export container' > /etc/dinit/init

# dhcpcd dinit service: run it only when the container has its own network.
# In host/none mode dhcpcd would reconfigure the phone's real interfaces.
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
# host/none network mode: stay idle so dinit does not respawn in a loop
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

# Defense in depth: only touch container veth interfaces (eth*) and never
# Android-internal interfaces (rmnet*, dit*, epdg*, ...).
if [ -f /etc/dhcpcd.conf ] && ! grep -qx 'allowinterfaces eth\*' /etc/dhcpcd.conf; then
    echo 'allowinterfaces eth*' >> /etc/dhcpcd.conf
fi
EOF_RUN

# Clean package cache
RUN apk cache clean && rm -rf /var/cache/apk/* /tmp/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Chimera Linux - Minimal (dinit)" \
      droidspaces.distro="Chimera Linux" \
      droidspaces.description="Minimal Chimera Linux ARM64 with musl libc, FreeBSD userland and native dinit init. CLI only." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /
