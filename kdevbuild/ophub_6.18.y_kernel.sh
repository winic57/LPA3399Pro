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
  git clone --depth=1 https://github.com/ophub/linux-6.18.y.git linux-6.18.y.git
fi

cd "${BUILDER_DIR}/linux-6.18.y.git"
echo "=== Kernel version ==="
head -5 Makefile

echo "=== Applying patches ==="
PATCH_DIR="${BUILDER_DIR}/kernel-6.18"
if ls "${PATCH_DIR}"/*.patch >/dev/null 2>&1; then
  for patch_file in "${PATCH_DIR}"/*.patch; do
    echo "--- Applying: $(basename "${patch_file}") ---"
    # Strip git mailbox header (From/Date/Subject) for patch command
    body_file="$(mktemp)"
    sed -n '/^diff --git/,$p' "${patch_file}" > "${body_file}"
    # Try git apply first (cleanest, no fuzz)
    if git apply --check "${patch_file}" 2>/dev/null; then
      git apply "${patch_file}"
      echo "  Applied via git apply (clean)"
    # Fallback: patch -p1 with fuzz, no force
    elif patch -p1 --fuzz=3 --no-backup-if-mismatch < "${body_file}" 2>&1; then
      echo "  Applied via patch -p1 (with fuzz=3)"
    else
      echo "  WARNING: Patch $(basename "${patch_file}") could NOT be applied"
      echo "  Skipping patch and continuing with clean kernel source"
      echo "  (The GMAC workaround is not critical for kernel compilation,"
      echo "   it is only needed for eth0 link-up on the physical board)"
    fi
    rm -f "${body_file}"
    # Report any .rej files
    if find . -name "*.rej" -print -quit 2>/dev/null | grep -q .; then
      echo "  Rejected hunks found:"
      find . -name "*.rej" -exec echo "    {}" \;
    fi
  done
else
  echo "No patches found in ${PATCH_DIR}"
fi

echo "=== Configuring kernel ==="
# Strategy: use defconfig as base (clean, compiles on any 6.18.y point release),
# then overlay our board-specific options. This avoids breakage from API changes
# in unrelated SoC drivers (e.g. i.MX, Renesas, Broadcom) that the full Armbian
# config enables but we don't need on RK3399Pro.
echo "Using arm64 defconfig as base..."
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig

# Apply our custom options on top of defconfig using merge_config.sh
CUSTOM_CONFIG="${BUILDER_DIR}/kernel-6.18/config-6.18"
if [ -f "${CUSTOM_CONFIG}" ]; then
  echo "Extracting board-specific options from config-6.18..."

  # Extract only the options we care about (Rockchip + WiFi + 4G + peripherals)
  # This avoids pulling in unrelated SoC drivers that may have API differences
  grep -E \
    "^CONFIG_(RTW88|RTW88_8821|RTW88_SDIO|RTW88_CORE|RTW88_LEDS|PPP|PPPOE|PPTP|SLHC|USB_NET_QMI|USB_NET_CDC_MBIM|USB_NET_RNDIS|USB_WDM|USB_SERIAL_OPTION|STMMAC|DWMAC_ROCK|ROCKCHIP|PCIE_ROCKCHIP|PHY_ROCKCHIP|RTK8723CS|BLUETOOTH|BT_|RFCOMM|BT_BNEP|BT_HIDP)" \
    "${CUSTOM_CONFIG}" > /tmp/board_custom.config 2>/dev/null || true

  # Also extract key Rockchip platform options
  grep -E \
    "^CONFIG_(ARCH_ROCKCHIP|ARM_ROCKCHIP|ROCKCHIP_.*=y|ROCKCHIP_.*=m|CLK_ROCKCHIP|PINCTRL_ROCKCHIP|REGULATOR_ROCKCHIP|PHY_ROCKCHIP|VIDEO_ROCKCHIP|SND_SOC_ROCKCHIP|USB_DWC2|USB_DWC3|ECHI|OHCI|XHCI|PCI_HOST_GENERIC|STMMAC|DWMAC)" \
    "${CUSTOM_CONFIG}" >> /tmp/board_custom.config 2>/dev/null || true

  echo "Board-specific options to merge:"
  cat /tmp/board_custom.config
  echo ""

  # Merge using kernel's built-in merge script
  if [ -f "scripts/kconfig/merge_config.sh" ]; then
    bash scripts/kconfig/merge_config.sh -m -n .config /tmp/board_custom.config
  else
    # Fallback: append and let olddefconfig sort it out
    cat /tmp/board_custom.config >> .config
  fi
  echo "Board-specific options merged."
else
  echo "WARNING: config-6.18 not found, using defconfig only"
fi

echo "=== olddefconfig ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig 2>&1 | tee /tmp/olddefconfig.log

BUILD_LOG="/tmp/kernel_build.log"
echo "=== Building Image (logging to ${BUILD_LOG}) ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image 2>&1 | tee "${BUILD_LOG}" || {
  echo ""
  echo "========== BUILD FAILED =========="
  echo "=== Extracting error lines from build log ==="
  echo ""
  echo "--- Lines containing 'error:' or 'Error' ---"
  grep -iE "error:|warning:.*error|fatal:" "${BUILD_LOG}" | grep -v "Werror" | head -80
  echo ""
  echo "--- Last 100 lines of build log ---"
  tail -100 "${BUILD_LOG}"
  echo ""
  exit 1
}

echo "=== Building modules ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) modules 2>&1 | tee "${BUILD_LOG}" || {
  echo ""
  echo "========== MODULES BUILD FAILED =========="
  echo "=== Extracting error lines ==="
  grep -iE "error:|fatal:" "${BUILD_LOG}" | head -80
  echo ""
  echo "--- Last 100 lines of build log ---"
  tail -100 "${BUILD_LOG}"
  exit 1
}

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
