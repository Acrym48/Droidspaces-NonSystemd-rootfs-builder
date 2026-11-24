

# Void Linux musl Minimal - DroidSpaces
# Architecture: aarch64
# Libc: musl
# Init: runit

# --------------------------------------------------
# Bootstrap official Void Linux rootfs
# --------------------------------------------------
FROM alpine:3.23 AS bootstrap

RUN apk add --no-cache curl xz tar

WORKDIR /rootfs

RUN curl -fL \
    https://repo-default.voidlinux.org/live/current/void-aarch64-musl-ROOTFS-20250202.tar.xz \
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

# Install useful CLI packages
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
    dhcpcd

# Android networking groups and root permissions
RUN set -eux; \
    grep -q '^aid_inet:' /etc/group || \
        groupadd -g 3003 aid_inet; \
    grep -q '^aid_net_raw:' /etc/group || \
        groupadd -g 3004 aid_net_raw; \
    grep -q '^aid_net_admin:' /etc/group || \
        groupadd -g 3005 aid_net_admin; \
    usermod -a -G aid_inet,aid_net_raw root

# Basic configuration
RUN set -eux; \
    mkdir -p /run/sshd; \
    mkdir -p /etc/profile.d

# dhcpcd runit service: run it only when the container has its own network.
# In host/none mode dhcpcd would reconfigure the phone's real interfaces.
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
# enable via the real default service dir (do NOT replace /var/service)
ln -sf /etc/sv/ds-dhcp /etc/runit/runsvdir/default/ds-dhcp
EOF_RUN

# Verify runit installation and show useful diagnostics
RUN set -eux; \
    command -v xbps-install; \
    command -v runit; \
    command -v runsvdir; \
    ls -l /sbin/init; \
    ls -ld /etc/runit /etc/runit/runsvdir /etc/sv; \
    ls -l /etc/runit/runsvdir/default

# Clean package cache
RUN xbps-remove -O && \
    rm -rf /var/cache/xbps/*


# --------------------------------------------------
# Export rootfs for DroidSpaces
# --------------------------------------------------
FROM scratch AS export

LABEL droidspaces.name="Void Linux musl - Minimal (runit)" \
      droidspaces.distro="Void Linux musl" \
      droidspaces.description="Minimal Void Linux ARM64 with musl and native runit init. CLI only." \
      droidspaces.author="Acrym48"

COPY --from=customizer / /
