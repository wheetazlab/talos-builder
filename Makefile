PKG_VERSION = b1fc4c6
TALOS_VERSION = v1.12.4

PUSH ?= true
REGISTRY ?= ghcr.io

ifndef RPI_MODEL
RPI_MODEL = rpi5
endif
REGISTRY_USERNAME ?= talos-$(RPI_MODEL)
TAG ?= $(shell git describe --tags --exact-match)

SED ?= sed
ASSET_TYPE ?= installer
CONFIG_TXT = dtparam=i2c_arm=on

EXTENSIONS ?=
EXTENSION_ARGS = $(foreach ext,$(EXTENSIONS),--system-extension-image $(ext))

OVERLAY_OPTIONS ?=
OVERLAY_OPTION_ARGS = $(foreach opt,$(OVERLAY_OPTIONS),--overlay-option $(opt))

KERNEL_ARGS ?=
KERNEL_ARG_ARGS = $(foreach arg,$(KERNEL_ARGS),--extra-kernel-arg $(arg))

# Two patches are applied to sbc-raspberrypi v0.2.0 before the overlay build:
# 0001: Adds dtparam=pciex1 to config.txt so the RPi firmware enables the
#       BCM2712 PCIe lane (M.2 slot) and passes it to U-Boot in the DT.
# 0002: Full BCM2712 U-Boot PCIe driver support (per-chip config struct,
#       PERST#/bridge callbacks, SerDes PLL init) so NVMe enumerates on CM5.
#
# No custom kernel build required — upstream siderolabs kernel is used directly.
# nvme.ko (CONFIG_BLK_DEV_NVME=m) is already bundled in the Talos initramfs.
SBCOVERLAY_REPOSITORY = https://github.com/siderolabs/sbc-raspberrypi.git
SBCOVERLAY_VERSION ?= v0.2.0
SBCOVERLAY_CUSTOM_TAG = $(SBCOVERLAY_VERSION)-rpi5-uboot
SBCOVERLAY_IMAGE ?= $(REGISTRY)/$(REGISTRY_USERNAME)/sbc-raspberrypi:$(SBCOVERLAY_CUSTOM_TAG)

PKG_REPOSITORY = https://github.com/siderolabs/pkgs.git
TALOS_REPOSITORY = https://github.com/siderolabs/talos.git

CHECKOUTS_DIRECTORY := $(PWD)/checkouts
PATCHES_DIRECTORY := $(PWD)/patches

PKGS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/pkgs && git describe --tag --always --dirty --match v[0-9]\*)
TALOS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/talos && git describe --tag --always --dirty --match v[0-9]\*)

# Upstream siderolabs kernel — no custom kernel compile needed
UPSTREAM_KERNEL_IMAGE = ghcr.io/siderolabs/kernel:$(PKGS_TAG)

#
# Help
#
.PHONY: help
help:
	@echo "checkouts      : Clone repositories required for the build"
	@echo "patches-pi5    : Apply all patches for Raspberry Pi 5"
	@echo "patches-pi4    : Apply all patches for Raspberry Pi 4"
	@echo "kernel         : Build kernel"
	@echo "overlay        : Build sbc-raspberrypi overlay from source (adds dtparam=pciex1 to config.txt for CM5 M.2)"
	@echo "imager         : Build imager docker image"
	@echo "installer-base : Build installer-base docker image"
	@echo "kern_initramfs : Build kernel and initramfs"
	@echo "installer-pi5  : Build installer/image for Raspberry Pi 5"
	@echo "installer-pi4  : Build installer/image for Raspberry Pi 4"
	@echo "pi5            : Full build pipeline for Raspberry Pi 5"
	@echo "pi4            : Full build pipeline for Raspberry Pi 4"
	@echo "release        : Use only when building the final release, this will tag relevant images with the current Git tag."
	@echo "clean          : Clean up any remains"

#
# Checkouts
#
.PHONY: checkouts checkouts-clean
checkouts:
	git clone "$(PKG_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/pkgs"
	git -C "$(CHECKOUTS_DIRECTORY)/pkgs" checkout "$(PKG_VERSION)"
	git clone -c advice.detachedHead=false --branch "$(TALOS_VERSION)" "$(TALOS_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/talos"
	git clone -c advice.detachedHead=false --branch "$(SBCOVERLAY_VERSION)" "$(SBCOVERLAY_REPOSITORY)" "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi"

checkouts-clean:
	rm -rf "$(CHECKOUTS_DIRECTORY)/pkgs"
	rm -rf "$(CHECKOUTS_DIRECTORY)/talos"
	rm -rf "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi"

#
# Patches
#
.PHONY: patches patches-pi4 patches-pi5 patches-sbc
patches-sbc:
	cd "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/sbc-raspberrypi/0001-Enable-PCIe-for-CM5-IO-Board-NVMe.patch"
	cd "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/sbc-raspberrypi/0002-Add-BCM2712-PCIe-driver-support.patch"
	cp "$(PATCHES_DIRECTORY)"/siderolabs/u-boot/*.patch \
		"$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi/artifacts/u-boot/patches/"

patches-pi5: patches-sbc

patches-pi4:

# Backwards-compatible aliases
patches: patches-pi5
patches-sbc-only: patches-sbc

#
# Kernel
#
#
# Overlay (sbc-raspberrypi built from source with rpi_arm64_defconfig + BCM2712 PCIe fix)
#
.PHONY: overlay
overlay:
	cd "$(CHECKOUTS_DIRECTORY)/sbc-raspberrypi" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) \
			TAG=$(SBCOVERLAY_CUSTOM_TAG) PUSH=$(PUSH) \
			PLATFORM=linux/arm64 \
			sbc-raspberrypi

.PHONY: kernel
kernel:
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PLATFORM=linux/arm64 \
			kernel

.PHONY: imager
imager:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PKG_KERNEL=$(UPSTREAM_KERNEL_IMAGE) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			ABBREV_TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			imager

.PHONY: installer-base
installer-base:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PKG_KERNEL=$(UPSTREAM_KERNEL_IMAGE) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			ABBREV_TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			installer-base

.PHONY: kern_initramfs
kern_initramfs:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PKG_KERNEL=$(UPSTREAM_KERNEL_IMAGE) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			ABBREV_TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			kernel initramfs

#
# Installer/Image
#
# CONFIG_TXT (dtparam=i2c_arm=on) is always appended so I2C is available out
# of the box. dtparam=pciex1 is injected into config.txt at overlay build time
# by patches/siderolabs/sbc-raspberrypi/0001-Enable-PCIe-for-CM5-IO-Board-NVMe.patch.
# Any OVERLAY_OPTIONS passed via the environment or build.yaml are additive.
.PHONY: installer
installer:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		docker \
			run --rm -t -v ./_out:/out -v /dev:/dev --privileged $(REGISTRY)/$(REGISTRY_USERNAME)/imager:$(TALOS_VERSION) \
			$(ASSET_TYPE) --arch arm64 \
			--base-installer-image="$(REGISTRY)/$(REGISTRY_USERNAME)/installer-base:$(TALOS_VERSION)" \
			--overlay-name="rpi_5" \
			--overlay-image="$(SBCOVERLAY_IMAGE)" \
			--overlay-option="configTxtAppend=$(CONFIG_TXT)" \
			$(OVERLAY_OPTION_ARGS) \
			$(KERNEL_ARG_ARGS) \
			$(EXTENSION_ARGS)

# Backwards-compatible aliases
.PHONY: installer-pi5 installer-pi4
installer-pi5 installer-pi4: installer

#
# Release
#
.PHONY: release
# The installer image is already pushed as installer:$(TAG) by 'crane push' in CI.
# This target verifies the image exists in the registry.
# NOTE: We no longer pull installer:$(TALOS_TAG) and retag — that pulled a stale
#       dirty-tagged image from a previous build run, overwriting the correct image.
release:
	crane digest $(REGISTRY)/$(REGISTRY_USERNAME)/installer:$(TAG)

.PHONY: pi5
pi5: checkouts-clean checkouts patches-pi5 overlay kern_initramfs installer-base imager installer

.PHONY: pi4
pi4: checkouts-clean checkouts patches-pi4 kernel kern_initramfs installer-base imager installer

#
# Clean
#
.PHONY: clean
clean: checkouts-clean
