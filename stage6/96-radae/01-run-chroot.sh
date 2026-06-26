#!/usr/bin/env bash
set -euo pipefail

pushd /tmp

git clone https://github.com/peterbmarks/radae_decoder
git -C radae_decoder submodule update --init --recursive

pushd radae_decoder

arch="$(dpkg --print-architecture)"

# Patch the bundled Opus build for static linking and per-arch CFLAGS, same
# as the docker-builder's 20-radae.sh -- upstream's cmake/BuildOpus.cmake
# only targets x86_64 out of the box.
if [ -f cmake/BuildOpus.cmake ]; then
	if ! grep -q 'Add CMake imported target for static Opus' cmake/BuildOpus.cmake; then
		cat <<'EOF' >> cmake/BuildOpus.cmake

# --- Add CMake imported target for static Opus ---
if(NOT TARGET opus)
    add_library(opus STATIC IMPORTED)
    set_target_properties(opus PROPERTIES
        IMPORTED_LOCATION "${CMAKE_BINARY_DIR}/.cache/opus/src/.libs/libopus.a"
        INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_BINARY_DIR}/.cache/opus/src/include"
    )
endif()
EOF
	fi

	sed -i -E 's/(BUILD_COMMAND[[:space:]]+)make$/\1make -j6/' cmake/BuildOpus.cmake
	if [ "${arch}" = "arm64" ]; then
		sed -i 's/\\ -mno-dotprod//g' cmake/BuildOpus.cmake
		sed -i -E 's/CFLAGS=[^ )]+(\\ [^ )]+)*/CFLAGS=-march=armv8-a\\ -O2/' cmake/BuildOpus.cmake
		if ! grep -q -- '--disable-intrinsics' cmake/BuildOpus.cmake; then
			sed -i 's@./configure @./configure --disable-intrinsics @' cmake/BuildOpus.cmake
		fi
	elif [ "${arch}" = "armhf" ]; then
		sed -i 's/CFLAGS=-march=native\\ -O2/CFLAGS=-march=armv7-a+fp\\ -mfloat-abi=hard\\ -O2/' cmake/BuildOpus.cmake
		if ! grep -q -- '--disable-rtcd' cmake/BuildOpus.cmake; then
			sed -i 's@./configure @./configure --disable-rtcd @' cmake/BuildOpus.cmake
		fi
		if ! grep -q -- '--disable-asm' cmake/BuildOpus.cmake; then
			sed -i 's@./configure @./configure --disable-asm @' cmake/BuildOpus.cmake
		fi
		if ! grep -q -- '--disable-intrinsics' cmake/BuildOpus.cmake; then
			sed -i 's@./configure @./configure --disable-intrinsics @' cmake/BuildOpus.cmake
		fi
	fi
fi

# -Ppkg.minimal: CLI tools only, skips the libgtk-3-dev/libhamlib-dev GUI build-deps
dpkg-buildpackage -us -uc -j"$(nproc --ignore=4)" -Ppkg.minimal
popd

apt install -y ./webrx-rade-decode-minimal_*.deb

rm -rf radae_decoder webrx-rade-decode*

popd
