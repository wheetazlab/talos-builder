# Raspberry Pi 5 Talos Builder

> **This is a fork of [talos-rpi5/talos-builder](https://github.com/talos-rpi5/talos-builder).**
> See [What's different in this fork](#whats-different-in-this-fork) for changes made on top of upstream.

This repository serves as the glue to build custom Talos images for the Raspberry Pi 5. It patches the Kernel and Talos build process to use the Linux Kernel source provided by [raspberrypi/linux](https://github.com/raspberrypi/linux).

## Tested on

So far, this release has been verified on:

| ✅ Hardware                                                |
|------------------------------------------------------------|
| Raspberry Pi Compute Module 5 on Compute Module 5 IO Board |
| Raspberry Pi Compute Module 5 Lite on [DeskPi Super6C](https://wiki.deskpi.com/super6c/) |
| Raspberry Pi 5b with [RS-P11 for RS-P22 RPi5](https://wiki.52pi.com/index.php?title=EP-0234) |

## What's not working?

* Booting from USB: USB is only available once LINUX has booted up but not in U-Boot.

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

If you'd like to make modifications, it is possible to create your own build. Bellow is an example of the standard build.

```bash
# Clones all dependencies and applies the necessary patches
make checkouts patches

# Builds the Linux Kernel (can take a while)
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> kernel

# Builds the overlay (U-Boot, dtoverlays ...)
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> overlay

# Final step to build the installer and disk image
make REGISTRY=ghcr.io REGISTRY_USERNAME=<username> installer
```

## What's different in this fork

Only this repository (`talos-builder`) is forked. All other dependencies (`siderolabs/pkgs`, `siderolabs/talos`, `talos-rpi5/sbc-raspberrypi5`) are cloned directly from upstream by the Makefile — no changes were made to them.

### More granular build pipeline

Upstream uses a single high-level `make installer` step. This fork breaks the pipeline into explicit stages, matching the actual build graph more closely:

```
make checkouts patches-pi5
make kernel
make kern_initramfs
make installer-base
make imager
make overlay
make installer-pi5   # builds both installer and metal disk images
```

Build time on `ubuntu-24.04-arm`: ~1h 4m end-to-end. (this uses the free arm64 runner avaible via Github)

### Extensions support

Talos [system extensions](https://www.talos.dev/latest/talos-guides/configuration/system-extensions/) can be baked into the installer image at build time. This fork wires that capability into both the Makefile and the CI workflow.

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

## License

See [LICENSE](LICENSE).
