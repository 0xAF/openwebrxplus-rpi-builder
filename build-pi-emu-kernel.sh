#!/usr/bin/env bash

# Cross-compiles a Raspberry Pi 64-bit kernel from the same source tree and
# defconfig as the official linux-image-rpi-v8 package (the one stage0
# installs), with virtio + zram support added on top so it can run under
# QEMU's generic "-machine virt" the way pi-emu.sh boots it, without the
# ~90s boot stall waiting on /dev/zram0. This is NOT the exact binary
# Raspberry Pi Foundation ships (different build env/toolchain), but same
# source + same defconfig + same drivers, just with a few extra
# virtio/PCI/PSCI/zram options real Pi hardware doesn't need (real Pi has
# no PCIe-virtio, uses its own SMP boot protocol instead of PSCI, and
# already has zram via its stock kernel config -- it's only missing here
# because this build doesn't carry over the rootfs's matching modules).
#
# Output: pi-emu-kernel.img, next to this script. pi-emu.sh picks it up
# automatically (in preference to the generic ptrsr/pi-ci fallback kernel)
# if present.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

BRANCH="${BRANCH:-}"                          # empty = repo's default branch (currently maintained kernel line)
DEFCONFIG="${DEFCONFIG:-bcm2711_defconfig}"   # bcm2711_defconfig = Pi3/4/CM4/Zero2 (v8); bcm2712_defconfig = Pi5/CM5
JOBS="${JOBS:-$(nproc --ignore=4)}"
SRC_DIR="${SRC_DIR:-${SCRIPT_DIR}/pi-emu-kernel-src}"
OUT_KERNEL="${SCRIPT_DIR}/pi-emu-kernel.img"

exists() { type -P "$1" >/dev/null 2>&1; }
die() { echo "$*" >&2; exit 1; }

for tool in git make bc bison flex; do
	exists "$tool" || die "Missing build dep '$tool'. Debian/Ubuntu: sudo apt install git make bc bison flex libssl-dev libelf-dev. Arch: sudo pacman -S --needed git make bc bison flex base-devel"
done

# CROSS_COMPILE can be overridden (e.g. CROSS_COMPILE=aarch64-elf- if that's
# what you have installed instead of the full aarch64-linux-gnu- toolchain --
# the kernel doesn't link against libc, so either target works).
if [ "$(uname -m)" = "aarch64" ]; then
	CROSS_COMPILE="${CROSS_COMPILE-}"
else
	CROSS_COMPILE="${CROSS_COMPILE-aarch64-linux-gnu-}"
fi
exists "${CROSS_COMPILE}gcc" || die "Missing compiler '${CROSS_COMPILE}gcc'. Debian/Ubuntu: sudo apt install gcc-aarch64-linux-gnu. Arch (AUR): yay -S aarch64-linux-gnu-gcc. Or export CROSS_COMPILE=<prefix> to match a cross-gcc you already have installed."

export ARCH=arm64
export CROSS_COMPILE

if [ -d "$SRC_DIR" ]; then
	echo "INFO: Reusing existing source at ${SRC_DIR} (delete it to re-clone/switch branch)."
else
	echo "INFO: Cloning raspberrypi/linux${BRANCH:+ (branch $BRANCH)} -- this is a full kernel tree, takes a while..."
	clone_args=(--depth=1)
	[ -n "$BRANCH" ] && clone_args+=(--branch "$BRANCH")
	git clone "${clone_args[@]}" https://github.com/raspberrypi/linux "$SRC_DIR"
fi

cd "$SRC_DIR"

echo "INFO: Configuring (${DEFCONFIG} + virtio/qemu-virt additions)..."
make "$DEFCONFIG"

FRAGMENT="$(mktemp)"
trap 'rm -f "$FRAGMENT"' EXIT
cat > "$FRAGMENT" <<'EOF'
# PCI bus + the generic ECAM host bridge QEMU's "virt" machine exposes
# (real Pi4/5 already have CONFIG_PCI=y for the VL805/NVMe controller, but
# not the generic host bridge driver, since they use their own).
CONFIG_PCI=y
CONFIG_PCI_HOST_GENERIC=y
# Storage/net seen by pi-emu.sh's qemu command line (virtio-blk, virtio-net-pci)
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
# QEMU's virt machine brings up secondary CPUs (-smp) via PSCI; real Pi
# hardware uses its own boot protocol instead, so this is normally off.
CONFIG_ARM_PSCI_FW=y
# zram, built in (not =m) since this emulator never injects modules into the
# rootfs. Without it /dev/zram0 never appears and rpi-swap's systemd .device
# unit sits at systemd's ~90s default device timeout on every single boot.
CONFIG_ZRAM=y
CONFIG_ZRAM_WRITEBACK=y
CONFIG_CRYPTO_LZO=y
CONFIG_CRYPTO_LZ4=y
CONFIG_CRYPTO_ZSTD=y
EOF

./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT" >/dev/null
make olddefconfig

echo "INFO: Verifying required options actually made it into .config..."
missing=""
for sym in CONFIG_PCI CONFIG_PCI_HOST_GENERIC CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_ARM_PSCI_FW CONFIG_ZRAM CONFIG_ZSMALLOC CONFIG_ZRAM_WRITEBACK CONFIG_CRYPTO_LZO; do
	grep -q "^${sym}=y" .config || missing="${missing} ${sym}"
done
[ -z "$missing" ] || die "These required options didn't get enabled (likely a Kconfig dependency conflict with ${DEFCONFIG}):${missing}. Try 'cd ${SRC_DIR} && make menuconfig' to chase it manually."

echo "INFO: Building Image (-j${JOBS}, this takes a while)..."
make -j"$JOBS" Image

cp arch/arm64/boot/Image "$OUT_KERNEL"
echo
echo "Done -> ${OUT_KERNEL}"
echo "pi-emu.sh will use it automatically on the next run."
