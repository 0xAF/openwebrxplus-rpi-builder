#!/usr/bin/env bash
set -euo pipefail

install -m 644 files/openwebrx.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"
install -m 644 files/openwebrx-plus.list "${ROOTFS_DIR}/etc/apt/sources.list.d/"

gpg --dearmor < files/openwebrx.gpg.key > "${ROOTFS_DIR}/usr/share/keyrings/openwebrx.gpg"
gpg --dearmor < files/openwebrx-plus.gpg.key > "${ROOTFS_DIR}/etc/apt/trusted.gpg.d/openwebrx-plus.gpg"

on_chroot << EOF
# stage0 already configured debian.sources/raspi.sources (main+contrib+non-free+non-free-firmware)
# and fixed up the debian-archive-keyring; just pick up the new OWRX sources added above.
apt update

# fix previous broken installs (if any)
apt remove --purge -y soapysdr-module-sdrplay3 soapysdr0.8-module-sdrplay3 || true
apt --fix-broken install || true
EOF
