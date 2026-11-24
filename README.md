# Droidspaces Non-systemd RootFS Builder

Builds **systemd-free** rootfs tarballs for
[Droidspaces](https://github.com/ravindu644/Droidspaces-OSS) from Dockerfiles, publishes
them as GitHub releases, and regenerates `rootfs.json` on every release.

This is a fork of the upstream builder. Upstream ships systemd-based images; this fork only
keeps distributions that boot with their own native init. Right now that means Void Linux
with **runit** — glibc and musl flavours, `aarch64` only.

## Current templates

| Template | Arch | Libc | Init | Notes |
| --- | --- | --- | --- | --- |
| `Void-Minimal-runit` | aarch64 | glibc | runit | CLI only |
| `Void-musl-Minimal-runit` | aarch64 | musl | runit | CLI only |

Both are bootstrapped from the official Void Linux ROOTFS tarball, updated with `xbps`,
and include `base-system` plus a small CLI toolset (bash, curl, wget, nano, htop, sudo,
openssh, iproute2, iputils, procps-ng, dhcpcd).

`templates/armhf`, `templates/x86` and `templates/x86_64` are empty placeholders — add a
Dockerfile there if you want those architectures.

## Init and services (no systemd)

There is no `systemctl`, no journal and no systemd units anywhere in these images.

- PID 1 is runit (`/sbin/init`), started from `/etc/runit/1`, `2` and `3`.
- Service definitions live in `/etc/sv/<name>/`; a service is enabled by symlinking it into
  `/etc/runit/runsvdir/default/`.
- Manage services with `sv status <name>`, `sv up <name>`, `sv down <name>`,
  `sv restart <name>`.
- Do **not** replace `/var/service` in a template. On Void it is a symlink to the active
  runsvdir, and replacing it breaks service supervision.

### Networking

The templates add a `ds-dhcp` runit service. It starts `dhcpcd -B` only when the container
has its own network namespace (`net_mode` in `/run/droidspaces/container.config` is not
`host` or `none`). In `host`/`none` mode it idles, so `runsv` does not respawn it in a loop
and the phone's real interfaces are left alone.

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

- install an init that works as PID 1 without systemd (runit, OpenRC, s6, etc.);
- keep `/sbin/init` pointing at it;
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
