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

MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
KERNEL_JOBS_REQUESTED="${KERNEL_JOBS:-8}"
KERNEL_JOBS_MAX="$(nproc 2>/dev/null || echo 4)"
if [ "${KERNEL_JOBS_REQUESTED}" -gt "${KERNEL_JOBS_MAX}" ]; then
  KERNEL_JOBS="${KERNEL_JOBS_MAX}"
else
  KERNEL_JOBS="${KERNEL_JOBS_REQUESTED}"
fi
echo "=== Kernel build parallel jobs: requested -j${KERNEL_JOBS_REQUESTED}, effective -j${KERNEL_JOBS} (nproc=${KERNEL_JOBS_MAX}) ==="
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-${BUILDER_DIR}/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  mkdir -p "${CCACHE_DIR}"
  ccache -M "${CCACHE_MAXSIZE}" || true
  ccache -z || true
  # Kernel build accepts make variable values containing spaces when passed
  # as one array element. This lets private GHA reuse cached target/host objects.
  MAKE_ARGS+=("CC=ccache aarch64-linux-gnu-gcc" "HOSTCC=ccache gcc")
fi

cd "${BUILDER_DIR}"
echo "=== Cloning kernel source ==="
# Use official kernel.org v6.18.33 tag — matches our config-6.18 exactly.
# ophub/linux-6.18.y.git is v6.18.35 which has API breakage in several
# non-Rockchip drivers (i.MX clk, Freescale FEC) that our multiplatform
# config enables.
KERNEL_TARBALL="v6.18.33.tar.gz"
KERNEL_URL="https://github.com/unifreq/linux-6.18.y/archive/refs/tags/${KERNEL_TARBALL}"

if [ ! -d linux-6.18.33 ]; then
  echo "Downloading kernel ${KERNEL_TARBALL}..."
  wget -q --show-progress "${KERNEL_URL}" -O "/tmp/${KERNEL_TARBALL}"
  echo "Extracting..."
  tar xf "/tmp/${KERNEL_TARBALL}" -C "${BUILDER_DIR}"
  mv "${BUILDER_DIR}/linux-6.18.y-6.18.33" "${BUILDER_DIR}/linux-6.18.33"
  rm -f "/tmp/${KERNEL_TARBALL}"
fi

cd "${BUILDER_DIR}/linux-6.18.33"
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
    if GIT_CEILING_DIRECTORIES="${BUILDER_DIR}" git apply --check "${patch_file}" 2>/dev/null; then
      GIT_CEILING_DIRECTORIES="${BUILDER_DIR}" git apply "${patch_file}"
      echo "  Applied via git apply (clean)"
    # Fallback: patch -p1 with fuzz, no force
    elif patch -p1 --fuzz=3 --no-backup-if-mismatch < "${body_file}" 2>&1; then
      echo "  Applied via patch -p1 (with fuzz=3)"
    else
      echo "  ERROR: Patch $(basename "${patch_file}") could NOT be applied"
      echo "  Refusing to continue: a successful build without required patches is a false positive."
      rm -f "${body_file}"
      exit 1
    fi
    rm -f "${body_file}"
    # Report any .rej files and fail immediately.
    if find . -name "*.rej" -print -quit 2>/dev/null | grep -q .; then
      echo "  ERROR: rejected hunks found:"
      find . -name "*.rej" -exec echo "    {}" \;
      exit 1
    fi
  done
else
  echo "No patches found in ${PATCH_DIR}"
fi

echo "=== Copying custom DTS ==="
shopt -s nullglob
for dts_file in "${PATCH_DIR}"/rk3399pro-neardi-linux-lc110*.dts; do
  dtb_name="$(basename "${dts_file%.dts}.dtb")"
  cp -v "${dts_file}" arch/arm64/boot/dts/rockchip/
  if ! grep -q "${dtb_name}" arch/arm64/boot/dts/rockchip/Makefile; then
    echo "Adding ${dtb_name} to Makefile..."
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += ${dtb_name}" >> arch/arm64/boot/dts/rockchip/Makefile
  fi
done
shopt -u nullglob


echo "=== Configuring kernel ==="
# Use our full config-6.18 (matches kernel 6.18.33 exactly)
CUSTOM_CONFIG="${BUILDER_DIR}/kernel-6.18/config-6.18"
if [ -f "${CUSTOM_CONFIG}" ]; then
  cp -a "${CUSTOM_CONFIG}" .config
  echo "Using config-6.18 from repo (kernel $(head -3 .config | grep 'Linux/arm64'))"
else
  echo "WARNING: config-6.18 not found, using defconfig"
  make "${MAKE_ARGS[@]}" defconfig
fi

# Disable i.MX clock drivers that have API breakage on this kernel version.
# The __devm_clk_hw_register_gate function gained a new parameter that the
# imx8mp-audiomix driver doesn't pass. We don't need i.MX drivers on RK3399Pro.
echo "=== Disabling problematic non-Rockchip drivers ==="
sed -i 's/^CONFIG_CLK_IMX8MM=y/# CONFIG_CLK_IMX8MM is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MN=y/# CONFIG_CLK_IMX8MN is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MP=y/# CONFIG_CLK_IMX8MP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MQ=y/# CONFIG_CLK_IMX8MQ is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8QXP=y/# CONFIG_CLK_IMX8QXP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8ULP=y/# CONFIG_CLK_IMX8ULP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX93=y/# CONFIG_CLK_IMX93 is not set/' .config
echo "Disabled: CONFIG_CLK_IMX8xx (i.MX clock drivers not needed on RK3399Pro)"

echo "=== olddefconfig ==="
make "${MAKE_ARGS[@]}" olddefconfig 2>&1 | tee /tmp/olddefconfig.log

BUILD_LOG="/tmp/kernel_build.log"
echo "=== Building Image (logging to ${BUILD_LOG}) ==="
make "${MAKE_ARGS[@]}" -j"${KERNEL_JOBS}" Image 2>&1 | tee "${BUILD_LOG}" || {
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
make "${MAKE_ARGS[@]}" -j"${KERNEL_JOBS}" modules 2>&1 | tee "${BUILD_LOG}" || {
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
make "${MAKE_ARGS[@]}" -j"${KERNEL_JOBS}" dtbs

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

if command -v ccache >/dev/null 2>&1; then ccache -s || true; fi
echo "=== Build completed successfully! ==="
