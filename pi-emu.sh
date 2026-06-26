#!/bin/bash

# This emulator is for quick network/web-UI smoke tests only (does the image
# boot, does nginx/openwebrx come up, is the web UI reachable). By default it
# boots a generic virtio-capable kernel (borrowed from ptrsr/pi-ci) instead of
# the real kernel installed in the image, so /lib/modules/$(uname -r) doesn't
# match and zram (and anything else module-based) won't work here.
#
# Run ./build-pi-emu-kernel.sh once to cross-compile the real Raspberry Pi
# kernel source/defconfig with virtio support added on top -- if
# pi-emu-kernel.img is present, it's used instead of the generic fallback.
# That kernel already has xHCI built in (real Pi4/5 need it for their own
# USB3 controller), so the optional USB passthrough below (3rd arg) gets a
# working usb-host controller in the guest. zram and other modules still
# won't work unless matching modules get injected into the rootfs, which
# this script doesn't do.
#
# QEMU's raspi3b/raspi4b machine types (closer to real hardware) only
# implement the BCM2835 firmware/mailbox interface partially, so an
# unmodified stock kernel doesn't boot there at all (no console output, UART
# never gets clocked). For zram or other module-dependent testing, flash the
# image to an SD card and test on actual Raspberry Pi hardware.

exists() { type -P $1 >/dev/null 2>&1; }
die() { echo "$*"; exit 1; }

exists qemu-img || die "you need qemu-img installed..."
exists mcopy || die "you need mtools installed..."
exists qemu-system-aarch64 || die "you need qemu-system-aarch64 installed..."
exists fdisk || die "you need fdisk installed..."
exists awk || die "you need awk installed..."
exists unzip || die "you need unzip installed..."

if [ "$EUID" -ne 0 ]; then
	die "ERROR: This script must be run as root."
fi

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
CUSTOM_KERNEL="$SCRIPT_DIR/pi-emu-kernel.img"
FALLBACK_KERNEL="$SCRIPT_DIR/pi-ci-fallback-kernel.img"

if [ -f "$CUSTOM_KERNEL" ]; then
	echo "INFO: Using custom-built kernel (real RPi source + virtio, see build-pi-emu-kernel.sh) at ${CUSTOM_KERNEL}."
	BOOT_KERNEL="$CUSTOM_KERNEL"
else
	if [ ! -f "$FALLBACK_KERNEL" ]; then
		exists docker || die "you need docker installed to fetch the generic test kernel (one-time)..."
		echo "INFO: Fetching generic test kernel from ptrsr/pi-ci (one-time)..."
		cid=$(docker create ptrsr/pi-ci:latest) || die "could not pull/create ptrsr/pi-ci"
		docker cp "$cid":/base/kernel.img "$FALLBACK_KERNEL"
		docker rm "$cid" >/dev/null
	fi
	BOOT_KERNEL="$FALLBACK_KERNEL"
fi

input=$1
USB_DEV=$2
if [ -z "$input" ]; then
	die "Usage: $0 <path-to-OpenWebRX-zip-or-img> [usb-vendorid:productid]"
fi
[ -f "$input" ] || die "File not found: $input"

USB_ARGS=()
if [ -n "$USB_DEV" ]; then
	exists lsusb || die "you need usbutils (lsusb) installed to pass through a USB device..."
	VID="${USB_DEV%%:*}"
	PID="${USB_DEV##*:}"
	usb_desc="$(lsusb -d "${VID}:${PID}" 2>/dev/null)"
	[ -n "$usb_desc" ] || die "USB device ${USB_DEV} not found on host (check 'lsusb' for vendorid:productid)"
	echo "INFO: Passing through USB device ${USB_DEV}: ${usb_desc#*: }"
	USB_ARGS=(-device qemu-xhci,id=usbbus -device "usb-host,bus=usbbus.0,vendorid=0x${VID},productid=0x${PID}")
fi

# The qcow2 disk is named after the source image and kept in emu-data/
# across runs, so a raspi-config filesystem resize (which only takes effect
# after a reboot) survives stopping/restarting the emulator. Delete that
# .qcow2 file (or the whole emu-data/ dir) to start over from the .img.
#
# The source .img itself is left where it lands (next to the zip, or
# wherever it already was) so it can be passed directly on later runs
# without re-extracting the zip.
mkdir -p emu-data

if unzip -l "$input" >/dev/null 2>&1; then
	extract_dir="$(dirname "$input")"
	expected_name="$(unzip -l "$input" | awk '/\.img$/{print $NF; exit}')"
	[ -n "$expected_name" ] || die "No OpenWebRX image found inside ${input}"
	IMAGE_FILE="$extract_dir/$expected_name"

	if [ -f "$IMAGE_FILE" ]; then
		echo "INFO: ${input} was already extracted, reusing ${IMAGE_FILE} (delete it to force re-extraction)."
	else
		echo "INFO: ${input} is a zip archive, extracting next to it..."
		unzip -o "$input" -d "$extract_dir"
		[ -f "$IMAGE_FILE" ] || die "No OpenWebRX image found inside ${input}"
		echo "INFO: extracted image kept at ${IMAGE_FILE} -- pass it directly next time to skip unzipping."
	fi
else
	echo "INFO: ${input} is not a zip archive, using it directly as the image..."
	IMAGE_FILE="$input"
fi

IMAGE_BASENAME="$(basename "${IMAGE_FILE}")"
QCOW_FILE="emu-data/${IMAGE_BASENAME%.img}.qcow2"

if [ -f "$QCOW_FILE" ]; then
	echo "INFO: Reusing existing disk ${QCOW_FILE} (keeps any raspi-config filesystem resize from a previous boot)."
	echo "INFO: To start over from ${IMAGE_FILE}, delete ${QCOW_FILE} (or the whole emu-data/ dir) and re-run."
else
	echo "INFO: No existing disk for this image yet, preparing ${QCOW_FILE}..."

	CURRENT_SIZE=$(stat -c%s "${IMAGE_FILE}")
	NEXT_POWER_OF_TWO=$(python3 -c "import math; print(2**(math.ceil(math.log(${CURRENT_SIZE}, 2))))")
	OFFSET=$(fdisk -lu ${IMAGE_FILE} | awk '/^Sector size/ {sector_size=$4} /FAT32 \(LBA\)/ {print $2 * sector_size}')

	echo "Image: $IMAGE_FILE, size: $(($CURRENT_SIZE/1024/1024)) MB, will resize to: $(($NEXT_POWER_OF_TWO/1024/1024)) MB"
	echo
	echo "You need to run 'raspi-config' and use Advanced menu to resize the FS internaly..."
	echo
	echo "Resizing image..."
	qemu-img resize -f raw "${IMAGE_FILE}" "${NEXT_POWER_OF_TWO}"

	echo "Preparing mtools..."
	echo "drive x: file=\"${IMAGE_FILE}\" offset=${OFFSET}" > ~/.mtoolsrc

	echo "Creating default user pi:raspberry and enabling ssh"
	touch ssh
	echo 'pi:$6$rBoByrWRKMY1EHFy$ho.LISnfm83CLBWBE/yqJ6Lq1TinRlxw/ImMTPcvvMuUfhQYcMmFnpFXUPowjy2br1NA0IACwF9JKugSNuHoe0' > userconf
	mcopy -o ssh x:/
	mcopy -o userconf x:/
	rm -f ssh userconf

	qemu-img convert -f raw "${IMAGE_FILE}" -O qcow2 "${QCOW_FILE}"
fi

echo;echo
echo ----------------------------------------------------
echo "Use Ctrl+a c to get QEMU console, then 'quit' (or system_powerdown) to shutdown cleanly."
echo "OWRX: http://localhost:8073 or http://localhost:8080"
echo "SSH:  ssh pi@localhost -p 2222 # password: raspberry"
echo "Disk: ${QCOW_FILE} (delete it, or emu-data/, to start fresh from ${IMAGE_FILE})"
[ -n "$USB_DEV" ] && echo "USB:  passthrough ${USB_DEV}"
echo ----------------------------------------------------
echo "Starting pi-emu with OpenWebRX image..."
echo;echo;echo

qemu-system-aarch64 \
	-machine virt -cpu cortex-a72 -m 2G -smp 4 \
	-kernel "$BOOT_KERNEL" \
	-append "rw console=ttyAMA0 root=/dev/vda2 rootfstype=ext4 rootdelay=1 loglevel=2 systemd.mask=systemd-zram-setup@zram0.service" \
	-drive file="${QCOW_FILE}",format=qcow2,id=hd0,if=none,cache=writeback \
	-device virtio-blk,drive=hd0,bootindex=0 \
	-netdev user,id=mynet,hostfwd=tcp::2222-:22,hostfwd=tcp::8073-:8073,hostfwd=tcp::8080-:80 \
	-device virtio-net-pci,netdev=mynet \
	"${USB_ARGS[@]}" \
	-nographic -no-reboot
