# Raspberry Pi 5 Talos Builder

This repository builds custom Talos images for the Raspberry Pi 5 and Compute Module 5. It applies minimal patches on top of the official [siderolabs/pkgs](https://github.com/siderolabs/pkgs) upstream kernel and uses the official [siderolabs/sbc-raspberrypi](https://github.com/siderolabs/sbc-raspberrypi) overlay for CM5 DTBs and U-Boot.

## Tested on

So far, this release has been verified on:

| ✅ Hardware                                                |
|------------------------------------------------------------|
| Raspberry Pi Compute Module 5 on Compute Module 5 IO Board |
| Raspberry Pi Compute Module 5 Lite on [DeskPi Super6C](https://wiki.deskpi.com/super6c/) |
| Raspberry Pi 5b with [RS-P11 for RS-P22 RPi5](https://wiki.52pi.com/index.php?title=EP-0234) |

## What's not working?

* **Booting from USB:** USB on the RPi5/CM5 is routed through the RP1 southbridge, which requires firmware initialisation that only happens during Linux boot. U-Boot runs before that initialisation occurs, so USB devices are not visible at boot time and cannot be used as a boot source.

## How to use?

The releases on this repository align with the corresponding Talos version. There is a raw disk image (initial setup) and an installer image (upgrades) provided.

### Examples

Initial:

```bash
unzstd metal-arm64-rpi.raw.zst
dd if=metal-arm64-rpi.raw of=<disk> bs=4M status=progress
sync
```

Upgrade:

```bash
talosctl upgrade \
  --nodes <node IP> \
  --image ghcr.io/talos-rpi5/installer:<version>
```

## Building

### Using GitHub Actions

The CI workflow builds and publishes images automatically. It is triggered when you push a version tag:

- **Push a tag** matching `v*.*.*` — this triggers the full build and creates a GitHub Release:
  ```bash
  git tag v1.12.4
  git push origin v1.12.4
  ```

### Local build

If you'd like to make modifications, it is possible to create your own build. Below is an example of the standard build.

```bash
# Clones all dependencies and applies the necessary patches
make checkouts patches

# Builds the Linux Kernel (can take a while)
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> kernel

# Builds kernel initramfs, installer-base, and imager
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> kern_initramfs installer-base imager

# Final step to build the installer and disk image
# The official sbc-raspberrypi:v0.1.9 overlay (includes CM5 DTBs) is pulled automatically
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> installer-pi5
```

### Extensions support

Talos [system extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/) can be baked into the installer image at build time.

**Makefile variables:**

```makefile
EXTENSIONS ?=
EXTENSION_ARGS = $(foreach ext,$(EXTENSIONS),--system-extension-image $(ext))
```

`EXTENSIONS` is a space-separated list of `image:tag@sha256:digest` references passed as a make variable at build time — no Makefile edits needed. Internally, the Makefile expands each entry into a `--system-extension-image` flag and passes them all to the Talos imager.

**Adding extensions to the CI build:**

Just add a new `EXTENSION_*` env var at the top of `.github/workflows/build.yaml` — the digest resolution step automatically loops through all vars matching that prefix:

```yaml
env:
  EXTENSION_ISCSI_IMAGE: ghcr.io/siderolabs/iscsi-tools:v0.2.0
  EXTENSION_UTIL_LINUX_IMAGE: ghcr.io/siderolabs/util-linux-tools:2.41.2
  EXTENSION_MY_IMAGE: ghcr.io/siderolabs/my-extension:v1.0.0   # ← just add this
```

The workflow resolves the digest for each at build time and assembles the full `EXTENSIONS` string automatically.

**Adding extensions for a local build:**

```bash
# Resolve the digest first
DIGEST=$(crane digest ghcr.io/siderolabs/foo-extension:v1.0.0)

make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> \
  EXTENSIONS="ghcr.io/siderolabs/foo-extension:v1.0.0@${DIGEST}" \
  installer-pi5
```

Pass multiple extensions as a space-separated string inside the quotes.

## v1.12.4 — Migration to Official Upstream Components

Starting with v1.12.4 this build switched from the custom `talos-rpi5/sbc-raspberrypi5` overlay to the official Siderolabs overlay, and from the Raspberry Pi kernel fork to the mainstream upstream kernel. Here is what changed and why.

### What changed

| Component | Before (v1.11.5) | After (v1.12.4) |
|---|---|---|
| Kernel | `raspberrypi/linux stable_20250428` (6.12.x RPi fork) | Upstream Linux **6.18.9** (via `siderolabs/pkgs@b1fc4c6`) |
| Overlay | `talos-rpi5/sbc-raspberrypi5` (custom, built from source) | `ghcr.io/siderolabs/sbc-raspberrypi:v0.1.9` (official) |
| CM5 DTBs | Provided by RPi kernel fork | Provided by `sbc-raspberrypi:v0.1.9` (builds all `bcm2712*.dtb` from RPi kernel) |
| NF_TABLES_BRIDGE | Patched in | Already `=y` in upstream 6.18.9 |
| RP1 drivers | Patched in as RPi-fork-specific configs | Already `=y` upstream (`CONFIG_MISC_RP1`) |
| pi5 build pipeline | `checkouts → patches → kernel → initramfs → installer-base → imager → overlay → installer` | `checkouts → patches → kernel → initramfs → installer-base → imager → installer` (no overlay build — official image pulled at runtime) |

### Why we switched

**CM5 support is now official.** `siderolabs/sbc-raspberrypi v0.1.9` (released February 24, 2026) builds DTBs
directly from `raspberrypi/linux stable_20250428`, which includes all CM5 device trees:
`bcm2712-rpi-cm5-cm5io.dtb`, `bcm2712-rpi-cm5-cm4io.dtb`, `bcm2712-rpi-cm5l-*.dtb`. There is no longer a
need to maintain a separate overlay build.

**The RPi kernel fork is stuck at 6.12.x.** The latest `raspberrypi/linux` tag (`stable_20250916`) is based on
Linux 6.12. The `siderolabs/pkgs` build toolchain for Talos 1.12.x targets 6.18.x, making the kernel swap
approach from v1.11.x incompatible.

**Most RPi5-specific kernel configs landed upstream.** Linux 6.18 includes `CONFIG_MISC_RP1=y`,
`CONFIG_NF_TABLES_BRIDGE=y`, and full RP1 peripheral support in the mainline tree. The large 1200-line
kernel config patch from v1.11.x is no longer needed.

### What we still patch

One kernel config change is still required because Talos must be able to boot from NVMe at initrd time:

```
CONFIG_BLK_DEV_NVME=m  →  CONFIG_BLK_DEV_NVME=y
```

Without this the NVMe driver is a loadable module and is not available early enough in the boot sequence for
the root filesystem to be found. The official upstream config still ships it as `=m` as of pkgs `b1fc4c6`.

The macOS `sed` compatibility patch for the Talos Makefile (`talos/0002-Makefile.patch`) is also retained for
local builds on macOS.

## License

See [LICENSE](LICENSE).
