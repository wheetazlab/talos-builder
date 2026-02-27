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

SBCOVERLAY_IMAGE ?= ghcr.io/siderolabs/sbc-raspberrypi:v0.1.9

PKG_REPOSITORY = https://github.com/siderolabs/pkgs.git
TALOS_REPOSITORY = https://github.com/siderolabs/talos.git

CHECKOUTS_DIRECTORY := $(PWD)/checkouts
PATCHES_DIRECTORY := $(PWD)/patches

PKGS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/pkgs && git describe --tag --always --dirty --match v[0-9]\*)
TALOS_TAG = $(shell cd $(CHECKOUTS_DIRECTORY)/talos && git describe --tag --always --dirty --match v[0-9]\*)

#
# Help
#
.PHONY: help
help:
	@echo "checkouts      : Clone repositories required for the build"
	@echo "patches-pi5    : Apply all patches for Raspberry Pi 5"
	@echo "patches-pi4    : Apply all patches for Raspberry Pi 4"
	@echo "kernel         : Build kernel"
	@echo "overlay        : (Not used - official sbc-raspberrypi:v0.1.9 overlay includes CM5 DTBs)"
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

checkouts-clean:
	rm -rf "$(CHECKOUTS_DIRECTORY)/pkgs"
	rm -rf "$(CHECKOUTS_DIRECTORY)/talos"

#
# Patches
#
.PHONY: patches-pkgs patches-talos patches patches-pkgs-4 patches-pi4 patches-pi5
patches-pkgs:
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/pkgs/0001-Patched-for-Raspberry-Pi-5.patch"

patches-talos:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/talos/0001-remove-nvme-ko-from-modules-list.patch"
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/talos/0002-Makefile.patch"

patches-pi5: patches-pkgs patches-talos

patches-pkgs-4:
	cd "$(CHECKOUTS_DIRECTORY)/pkgs" && \
		git apply "$(PATCHES_DIRECTORY)/siderolabs/pkgs/0002-Patched-for-Raspberry-Pi-4.patch"

patches-pi4: patches-pkgs patches-pkgs-4 patches-talos

# Backwards-compatible alias
patches: patches-pi5

#
# Kernel
#
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
			PKG_KERNEL=$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			imager

.PHONY: installer-base
installer-base:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PKG_KERNEL=$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			installer-base

.PHONY: kern_initramfs
kern_initramfs:
	cd "$(CHECKOUTS_DIRECTORY)/talos" && \
		$(MAKE) \
			REGISTRY=$(REGISTRY) USERNAME=$(REGISTRY_USERNAME) PUSH=$(PUSH) \
			PKG_KERNEL=$(REGISTRY)/$(REGISTRY_USERNAME)/kernel:$(PKGS_TAG) \
			INSTALLER_ARCH=arm64 PLATFORM=linux/arm64 SED=$(SED) \
			TAG=$(TALOS_VERSION) \
			TARGET_ARGS="$(TARGET_ARGS)" \
			kernel initramfs

#
# Installer/Image
#
# CONFIG_TXT (dtparam=i2c_arm=on by default) is always prepended so I2C is
# available out of the box. Any OVERLAY_OPTIONS passed via the environment
# or build.yaml are appended after, keeping them fully additive.
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
pi5: checkouts-clean checkouts patches-pi5 kernel kern_initramfs installer-base imager installer

.PHONY: pi4
pi4: checkouts-clean checkouts patches-pi4 kernel kern_initramfs installer-base imager installer

#
# Clean
#
.PHONY: clean
clean: checkouts-clean
