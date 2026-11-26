# Droidspaces Non-systemd RootFS Builder

Builds **systemd-free** rootfs tarballs for
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) from Dockerfiles, publishes
them as GitHub releases, and regenerates `rootfs.json` on every release.

This is a fork of the upstream builder. Upstream ships systemd-based images; this fork only
keeps distributions that boot with their own native init. Right now that means Void Linux
with **runit**, Chimera Linux with **dinit** and Adélie Linux with **OpenRC**. All templates are `aarch64`.

## Current templates

| Template | Arch | Libc | Init | Notes |
| --- | --- | --- | --- | --- |
| `Void-Minimal-runit` | aarch64 | glibc | runit | CLI only |
| `Void-musl-Minimal-runit` | aarch64 | musl | runit | CLI only |
| `Chimera-Minimal-dinit` | aarch64 | musl | dinit | CLI only, FreeBSD userland |
| `Void-Desktop-runit` | aarch64 | glibc | runit | XFCE4 desktop |
| `Void-musl-Desktop-runit` | aarch64 | musl | runit | XFCE4 desktop |
| `Chimera-Desktop-dinit` | aarch64 | musl | dinit | XFCE4 desktop |
| `Adelie-Desktop-openrc` | aarch64 | musl | OpenRC | XFCE4 desktop |
| `Alpine-Desktop-openrc` | aarch64 | musl | OpenRC | XFCE4 desktop |
| `Devuan-Minimal-openrc` | aarch64 | glibc | OpenRC | CLI only |
| `Devuan-Desktop-openrc` | aarch64 | glibc | OpenRC | XFCE4 desktop |
| `Devuan-Minimal-runit` | aarch64 | glibc | runit | CLI only |
| `Devuan-Desktop-runit` | aarch64 | glibc | runit | XFCE4 desktop |
| `Devuan-Minimal-sysvinit` | aarch64 | glibc | sysvinit | CLI only |
| `Devuan-Desktop-sysvinit` | aarch64 | glibc | sysvinit | XFCE4 desktop |

The Void templates are bootstrapped from the official Void Linux ROOTFS tarball, updated
with `xbps`, and include `base-system` plus a small CLI toolset (bash, curl, wget, nano,
htop, sudo, openssh, iproute2, iputils, procps-ng, dhcpcd).

The Chimera template is bootstrapped from the official Chimera `ROOTFS-*-bootstrap` tarball
and uses `apk` with the same kind of CLI toolset. It installs `dinit-chimera-device-none`
instead of udev, because a container has no hardware events to process.

## Init and services (no systemd)

There is no `systemctl`, no journal and no systemd units anywhere in these images. Each
template uses the init system the distro ships.

### Void Linux (runit)

- PID 1 is runit (`/sbin/init`), started from `/etc/runit/1`, `2` and `3`.
- Service definitions live in `/etc/sv/<name>/`; a service is enabled by symlinking it into
  `/etc/runit/runsvdir/default/`.
- Manage services with `sv status <name>`, `sv up <name>`, `sv down <name>`,
  `sv restart <name>`.
- Do **not** replace `/var/service` in a template. On Void it is a symlink to the active
  runsvdir, and replacing it breaks service supervision.

### Chimera Linux (dinit)

- PID 1 is dinit. `/sbin/init` is a symlink to the `dinit-chimera` wrapper, which sets up
  the environment and execs `/usr/bin/dinit --container`.
- Packaged service files live in `/usr/lib/dinit.d`; local ones go in `/etc/dinit.d`.
- Enable a service with `dinitctl enable <name>` (this creates a link in
  `/etc/dinit.d/boot.d`), disable it with `dinitctl disable <name>`.
- Inspect services with `dinitctl status <name>` and `dinitctl list`.
- `--container` keeps dinit from trying to halt or reboot the host. On shutdown it stops
  the services and exits, so Droidspaces can stop the container with plain SIGTERM.

`/sbin/init` is deliberately a symlink, not the regular wrapper file: Droidspaces treats a
regular `/sbin/init` as sysvinit and tries to talk to its initctl FIFO, which Chimera does
not have. As a symlink it is classified as an unknown init and stopped with SIGTERM.

### Adélie Linux (OpenRC)

- PID 1 is sysvinit, which is the binary Adélie's `sysvinit` package provides. It runs
  OpenRC through `/etc/inittab` (`/sbin/rc sysinit`, `boot`, `default`).
- Service definitions live in `/etc/init.d`; a service is enabled with
  `rc-update add <name> default`.
- Manage services with `rc-service <name> start|stop|restart` and inspect them with
  `rc-status`.
- The template hides `/sbin/openrc` and `/bin/s6-svscan` so Droidspaces does not
  misclassify the container as OpenRC or s6; it then uses the sysvinit initctl FIFO
  (`/run/initctl`) for a graceful stop.
- The `ds-dhcp` service starts `dhcpcd -B` only when `net_mode` in
  `/run/droidspaces/container.config` is not `host` or `none`.

### Alpine Linux (OpenRC)

- Alpine uses OpenRC natively. The template follows the official upstream Alpine minimal
  template (container-aware dhcpcd, `rc_sys="lxc"`, console getty).
- Service definitions live in `/etc/init.d`; enabled via `/etc/runlevels/`.
- Manage services with `rc-service <name> start|stop|restart` and `rc-update add <name> default`.
- The dhcpcd init script is container-aware (`--nodev`, `allowinterfaces eth*`,
  skips host/none network modes).
- XFCE autostart runs via an OpenRC service that waits for the X11 socket.

### Networking

The templates add a `ds-dhcp` service (runit on Void, dinit on Chimera). It starts
`dhcpcd -B` only when the container has its own network namespace (`net_mode` in
`/run/droidspaces/container.config` is not `host` or `none`). In `host`/`none` mode it
idles, so the supervisor does not respawn it in a loop and the phone's real interfaces are
left alone.

The templates also create the Android networking groups (`aid_inet` 3003, `aid_net_raw`
3004, `aid_net_admin` 3005) and add `root` to `aid_inet` and `aid_net_raw`, which is what
gives network access on Android kernels.

## Layout

```
archs.json                  supported architectures -> docker platform + CI runner
build.sh                    builds one template for one arch
templates/<arch>/<Name>.Dockerfile
scripts/generate_rootfs_json.py
scripts/cleanup_old_assets.py
rootfs.json                 generated, do not edit by hand
```

`scripts/bspwm`, `scripts/xfce-start`, `scripts/bashrc.sh` and similar files are inherited
from upstream and are not used by the current CLI-only templates.

## Adding a distro

Create `templates/<arch>/<Name>.Dockerfile`. That is the whole change.

The Dockerfile must end with an `export` stage carrying the metadata labels:

```dockerfile
FROM scratch AS export

LABEL droidspaces.name="Void Linux - Minimal (runit)" \
      droidspaces.distro="Void Linux" \
      droidspaces.description="Minimal Void Linux ARM64 with glibc and native runit init. CLI only." \
      droidspaces.author="Droidspaces developers"

COPY --from=customizer / /
```

`name`, `distro`, and `description` are required. `author` defaults to "Droidspaces
developers". Any extra `droidspaces.<key>` label is copied into the `rootfs.json` entry as
`<key>`.

Build context is the repo root, so `COPY scripts/...` works from any template.

For this fork, a new template must also:

- install an init that works as PID 1 without systemd (runit, dinit, OpenRC, s6, etc.);
- keep `/sbin/init` pointing at it;
- make sure Droidspaces can stop it gracefully: a regular `/sbin/init` file is treated as
  sysvinit, a symlink is treated as an unknown init and gets SIGTERM (see the Chimera
  template);
- enable services through the distro's own mechanism, not by calling `systemctl`;
- create the `aid_inet` / `aid_net_raw` groups and add `root` to them.

## Adding an architecture

Add a key to `archs.json` and create `templates/<arch>/`:

```json
"x86_64": { "platform": "linux/amd64", "runner": "ubuntu-latest" }
```

`platform` is the Docker build platform, `runner` is the GitHub Actions runner label used
for that arch.

## Building locally

```sh
./build.sh -a aarch64 -i Void-Minimal-runit
./build.sh -a aarch64 -i Chimera-Minimal-dinit
./build.sh -a aarch64 -i Adelie-Minimal-openrc
./build.sh -a aarch64 -i Adelie-Desktop-openrc
./build.sh -a aarch64 -i Void-Desktop-runit
./build.sh -a aarch64 -i Void-musl-Desktop-runit
./build.sh -a aarch64 -i Chimera-Desktop-dinit
./build.sh -a aarch64 -i Alpine-Desktop-openrc
```

Needs docker with buildx, jq, and xz. QEMU is registered automatically when the host cannot
run the target platform natively. The result is
`<Name>-Droidspaces-rootfs-<arch>-<YYYYMMDD>-<version>.tar.xz`.

## Checking labels

```sh
python3 scripts/generate_rootfs_json.py --lint
```

This validates every template's `droidspaces.*` labels without touching the network or
writing files.

## CI

`.github/workflows/build-rootfs-releases.yml` runs on push to `main`, weekly, or by hand.
It lints labels, builds every template in parallel on the runner for its arch, creates one
release with all tarballs, then regenerates and commits `rootfs.json`. The first failed
build cancels the rest and blocks the release. The manual `update_json_only` input
regenerates `rootfs.json` from the current latest release without building.

`.github/workflows/cleanup-old-assets.yml` prunes old releases, tags and workflow runs on a
weekly schedule.

## About `rootfs.json`

`rootfs.json` is generated from the labels in `templates/` plus the assets of the latest
release. Do not edit it by hand — CI commits it after each release. Until this fork
publishes its first release, the file still lists the upstream systemd images, so treat its
contents as stale.
