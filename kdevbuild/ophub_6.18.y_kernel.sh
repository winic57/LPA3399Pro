#!/bin/bash

set -eo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== Updating APT ==="
apt-get update
apt-get install -y ca-certificates
apt-get install -y --no-install-recommends \
  acl aptly aria2 axel bc binfmt-support binutils-aarch64-linux-gnu bison bsdextrautils \
  btrfs-progs build-essential busybox ca-certificates ccache clang coreutils cpio \
  crossbuild-essential-arm64 cryptsetup curl debian-archive-keyring debian-keyring debootstrap \
  device-tree-compiler dialog dirmngr distcc dosfstools dwarves e2fsprogs expect f2fs-tools fakeroot \
  fdisk file flex gawk gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi gdisk git gnupg gzip htop \
  imagemagick jq kmod lib32ncurses-dev lib32stdc++6 libbison-dev libc6-dev-armhf-cross libc6-i386 \
  libcrypto++-dev libelf-dev libfdt-dev libfile-fcntllock-perl libfl-dev libfuse-dev \
  libgcc-12-dev-arm64-cross libgmp3-dev liblz4-tool libmpc-dev libncurses-dev libncurses5 \
  libncurses5-dev libncursesw5-dev libpython2.7-dev libpython3-dev libssl-dev libusb-1.0-0-dev \
  linux-base lld llvm locales lsb-release lz4 lzma lzop make mtools ncurses-base ncurses-term \
  nfs-kernel-server ntpdate openssl p7zip p7zip-full parallel parted patch patchutils pbzip2 pigz \
  pixz pkg-config pv python2 python2-dev python3 python3-dev python3-distutils python3-pip \
  python3-setuptools python-is-python3 qemu-user-static rar rdfind rename rsync sed squashfs-tools \
  sudo swig tar tree u-boot-tools udev unzip util-linux uuid uuid-dev uuid-runtime vim wget whiptail \
  xfsprogs xsltproc xxd xz-utils zip zlib1g-dev zstd binwalk ripgrep

# Set locale
localedef -i zh_CN -f UTF-8 zh_CN.UTF-8 || true

BUILDER_DIR="/workspace"
OUTPUT_DIR="${BUILDER_DIR}/output"
mkdir -p "$OUTPUT_DIR"

cd "${BUILDER_DIR}"
echo "=== Cloning kernel source ==="
if [ ! -d linux-6.18.y.git ]; then
  git clone --progress https://github.com/ophub/linux-6.18.y.git linux-6.18.y.git
fi

cd "${BUILDER_DIR}/linux-6.18.y.git"
echo "=== Kernel version ==="
head -5 Makefile

echo "=== Applying patches ==="
PATCH_DIR="${BUILDER_DIR}/kernel-6.18"
if ls "${PATCH_DIR}"/*.patch >/dev/null 2>&1; then
  for patch_file in "${PATCH_DIR}"/*.patch; do
    echo "--- Applying: $(basename "${patch_file}") ---"
    # Try git apply first (handles renames and mode changes)
    if git apply --check "${patch_file}" 2>/dev/null; then
      git apply "${patch_file}"
      echo "  Applied via git apply"
    # Fallback: patch command with fuzz
    elif patch -p1 --fuzz=3 --no-backup-if-mismatch < "${patch_file}"; then
      echo "  Applied via patch -p1 (with fuzz)"
    else
      echo "  WARNING: Patch $(basename "${patch_file}") failed to apply cleanly"
      echo "  Attempting forced apply (may produce .rej files)..."
      patch -p1 --fuzz=3 --force < "${patch_file}" || true
      echo "  Check .rej files for rejected hunks"
    fi
  done
else
  echo "No patches found in ${PATCH_DIR}"
fi

echo "=== Configuring kernel ==="
if [ -f "${BUILDER_DIR}/kernel-6.18/config-6.18" ]; then
  cp -a "${BUILDER_DIR}/kernel-6.18/config-6.18" .config
  echo "Using config-6.18 from repo"
else
  echo "WARNING: config-6.18 not found, using defconfig"
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
fi

echo "=== olddefconfig ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig

echo "=== Building Image ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image

echo "=== Building modules ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) modules

echo "=== Building dtbs ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) dtbs

echo "=== Collecting output ==="
cp arch/arm64/boot/Image "$OUTPUT_DIR/"

mkdir -p dtbs
find . -name "rk3399*.dtb" -exec cp {} dtbs/ \;
tar -zcvf "$OUTPUT_DIR/dtbs.tar.gz" dtbs

mkdir -p kos
find . -name "*.ko" -exec cp {} kos/ \;
tar -zcvf "$OUTPUT_DIR/kos.tar.gz" kos

echo "=== Output ==="
ls -alh "$OUTPUT_DIR/"

echo "=== Build completed successfully! ==="
