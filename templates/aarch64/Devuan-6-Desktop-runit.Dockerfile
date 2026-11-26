# Dockerfile (XFCE, runit)
# Stage 1: Build and customize the rootfs for development (XFCE - Devuan 6 Excalibur, runit)
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

# Main installation layer (Minimal + CLI + GUI + runit)
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # Init: runit + runit-init
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
    # Compression tools
    zip \
    unzip \
    p7zip-full \
    bzip2 \
    xz-utils \
    tar \
    gzip \
    # System tools
    htop \
    btop \
    vim \
    nano \
    git \
    sudo \
    openssh-server \
    dhcpcd-base \
    net-tools \
    iptables \
    iputils-ping \
    iproute2 \
    dnsutils \
    usbutils \
    pciutils \
    lsof \
    psmisc \
    procps \
    fastfetch \
    kmod \
    # Wireless networking tools
    iw \
    # Logging & Rotation
    logrotate \
    # Development tools
    build-essential \
    gcc \
    g++ \
    gdb \
    make \
    cmake \
    autoconf \
    automake \
    libtool \
    pkg-config \
    # Additional dev tools
    clang \
    llvm \
    valgrind \
    strace \
    ltrace \
    # Python Development
    python3 \
    python3-pip \
    python3-dev \
    python3-venv \
    python-is-python3 \
    # File system tools
    gparted \
    dosfstools \
    exfatprogs \
    btrfs-progs \
    ntfs-3g \
    xfsprogs \
    jfsutils \
    hfsprogs \
    reiserfsprogs \
    cryptsetup \
    nilfs-tools \
    udftools \
    f2fs-tools \
    # Audio
    pulseaudio \
    pulseaudio-utils \
    pavucontrol \
    # XFCE Desktop Environment and essential tools
    xfce4 \
    desktop-base \
    xfce4-terminal \
    xfce4-session \
    xfce4-goodies \
    xfce4-taskmanager \
    mousepad \
    galculator \
    nemo-fileroller \
    ristretto \
    xfce4-screenshooter \
    catfish \
    xcursor-themes \
    xfce4-clipman-plugin \
    xinit \
    xorg \
    dbus-x11 \
    at-spi2-core \
    tumbler \
    # Icon themes
    adwaita-icon-theme-full \
    hicolor-icon-theme \
    gnome-icon-theme \
    tango-icon-theme \
    # GTK theme engines and popular themes
    gtk2-engines-murrine \
    gtk2-engines-pixbuf \
    arc-theme \
    numix-gtk-theme \
    papirus-icon-theme \
    greybird-gtk-theme \
    # Essential fonts for GUI rendering
    fonts-dejavu-core \
    fonts-liberation \
    fonts-liberation2 \
    fonts-noto-core \
    fonts-noto-ui-core \
    # File manager and GUI utilities
    thunar \
    thunar-volman \
    thunar-archive-plugin \
    thunar-media-tags-plugin \
    gvfs \
    gvfs-backends \
    gvfs-fuse \
    x11-xserver-utils \
    x11-utils \
    xclip \
    xsel \
    xfwm4 \
    xfconf \
    zenity \
    notification-daemon \
    # Browser (Firefox ESR)
    firefox-esr \
    # User directory management
    xdg-user-dirs \
    # PolicyKit for permissions
    polkitd \
    mate-polkit \
    # Docker
    docker.io \
    docker-compose \
    docker-cli \
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
    mkdir -p /var/run/sshd /run/dbus && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Initialize default user directories for GUI apps
    xdg-user-dirs-update && \
    # Remove default user if it exists
    deluser --remove-home debian || true

# Fix DHCP in the container (dhcpcd instead of systemd-networkd)
RUN printf '\n# Droidspaces: only manage ethernet-like interfaces\nallowinterfaces eth*\n' >> /etc/dhcpcd.conf

# Apply Android compatibility fixes and create runit services
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

# --- 2. runit directory layout ---
mkdir -p /etc/sv /etc/runit/runsvdir/default
ln -sfn /etc/runit/runsvdir/default /etc/service

# --- 3. ds-udev service (limited coldplug for Android) ---
mkdir -p /etc/sv/ds-udev
cat > /etc/sv/ds-udev/run << 'EOT'
#!/bin/sh
exec 2>&1

if grep -q '^net_mode=host$' /run/droidspaces/container.config 2>/dev/null; then
    exec chpst -b ds-udev pause
fi

if ! grep -q '^enable_hw_access=1$' /run/droidspaces/container.config 2>/dev/null; then
    exec chpst -b ds-udev pause
fi

UDEVD=""
for p in /sbin/udevd /usr/sbin/udevd /lib/udev/udevd /usr/lib/udev/udevd /lib/systemd/systemd-udevd /usr/lib/systemd/systemd-udevd; do
    if [ -x "$p" ]; then
        UDEVD="$p"
        break
    fi
done

[ -n "$UDEVD" ] || exit 1
"$UDEVD" --daemon
udevadm trigger --action=add --subsystem-match=usb --subsystem-match=block \
    --subsystem-match=input --subsystem-match=tty --subsystem-match=net
exec chpst -b ds-udev-watch sleep infinity
EOT
chmod +x /etc/sv/ds-udev/run

# --- 4. dbus service ---
mkdir -p /etc/sv/dbus
cat > /etc/sv/dbus/run << 'EOT'
#!/bin/sh
exec 2>&1
mkdir -p /run/dbus
dbus-uuidgen --ensure=/etc/machine-id
exec /usr/bin/dbus-daemon --system --nofork --nopidfile
EOT
chmod +x /etc/sv/dbus/run

# --- 5. sshd service ---
mkdir -p /etc/sv/sshd
cat > /etc/sv/sshd/run << 'EOT'
#!/bin/sh
exec 2>&1
mkdir -p /var/run/sshd
ssh-keygen -A >/dev/null 2>&1
exec /usr/sbin/sshd -D -e
EOT
chmod +x /etc/sv/sshd/run

# --- 6. ds-dhcp service (skip host and none) ---
mkdir -p /etc/sv/ds-dhcp
cat > /etc/sv/ds-dhcp/run << 'EOT'
#!/bin/sh
exec 2>&1

if ! grep -q '^net_mode=' /run/droidspaces/container.config 2>/dev/null || \
   grep -qE '^net_mode=(host|none)$' /run/droidspaces/container.config; then
    exec chpst -b ds-dhcp pause
fi

exec /usr/sbin/dhcpcd -B -q --nodev
EOT
chmod +x /etc/sv/ds-dhcp/run

# Enable core services in default runsvdir
for svc in ds-udev dbus sshd ds-dhcp; do
    ln -sfn "/etc/sv/$svc" "/etc/runit/runsvdir/default/$svc"
done

# Configure logrotate for Android
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# Mark fixes as completed
echo "Post-extraction fixes (runit) applied on $(date)" > /etc/droidspaces
EOF_RUN

# Install and enable XFCE autostart service (runit)
COPY scripts/xfce-start /usr/local/bin/xfce-start
RUN chmod +x /usr/local/bin/xfce-start && \
    mkdir -p /etc/sv/xfce-autostart && \
    cat > /etc/sv/xfce-autostart/run << 'EOT' && \
    chmod +x /etc/sv/xfce-autostart/run && \
    ln -sfn /etc/sv/xfce-autostart /etc/runit/runsvdir/default/xfce-autostart
#!/bin/sh
exec 2>&1

while true; do
    if [ -f /run/droidspaces/container.config ] && \
       grep -qE '^enable_(termux_)?x11=1' /run/droidspaces/container.config && \
       [ -S /tmp/.X11-unix/X5 ]; then
        exec /usr/local/bin/xfce-start
    fi
    sleep 2
done
EOT

# Update icon and font caches in a final setup layer
RUN gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true && \
    gtk-update-icon-cache -f /usr/share/icons/Adwaita 2>/dev/null || true && \
    gtk-update-icon-cache -f /usr/share/icons/Papirus 2>/dev/null || true && \
    gtk-update-icon-cache -f /usr/share/icons/Tango 2>/dev/null || true && \
    fc-cache -fv

# Fix xfwm4 vblank_mode for Turnip (Qualcomm GPU) - prevents XFCE compositor hang
COPY scripts/xfwm4.xml /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml
COPY scripts/xfwm4.xml /root/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml

RUN if [ -f /usr/share/xfwm4/defaults ]; then \
    if grep -q '^vblank_mode=' /usr/share/xfwm4/defaults; then \
        sed -i 's/^vblank_mode=.*/vblank_mode=off/' /usr/share/xfwm4/defaults; \
    else \
        echo 'vblank_mode=off' >> /usr/share/xfwm4/defaults; \
    fi; \
fi

# Copy binfmt script and register runit service
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
    mkdir -p /etc/sv/qemu-binfmt-register && \
    cat > /etc/sv/qemu-binfmt-register/run << 'EOT' && \
    chmod +x /etc/sv/qemu-binfmt-register/run && \
    ln -sfn /etc/sv/qemu-binfmt-register /etc/runit/runsvdir/default/qemu-binfmt-register
#!/bin/sh
exec 2>&1
/usr/local/bin/qemu-binfmt-register.sh
exec chpst -b qemu-binfmt-done pause
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

# Install custom mesa from lfdevs/mesa-for-android-container
COPY scripts/install-mesa /usr/local/bin/install-mesa
RUN chmod +x /usr/local/bin/install-mesa && \
    cp /etc/os-release /etc/os-release.bak && \
    printf 'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"\nNAME="Debian GNU/Linux"\nVERSION_ID="13"\nVERSION="13 (trixie)"\nVERSION_CODENAME=trixie\nID=debian\n' > /etc/os-release && \
    (install-mesa || { rc=$?; mv /etc/os-release.bak /etc/os-release; exit $rc; }) && \
    mv /etc/os-release.bak /etc/os-release


# Final cleanup of APT cache
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Stage 2: Export to scratch for extraction
FROM scratch AS export
LABEL droidspaces.name="Devuan GNU/Linux 6 (Excalibur) - XFCE (runit)" \
      droidspaces.distro="Devuan" \
      droidspaces.description="Devuan 6 XFCE rootfs with runit, basic packages, development tools, and Docker." \
      droidspaces.author="Droidspaces developers"

# Copy the entire filesystem from the customizer stage
COPY --from=customizer / /
