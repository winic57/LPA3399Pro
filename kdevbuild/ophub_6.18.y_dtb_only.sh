#!/bin/bash

set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

BUILDER_DIR="/workspace"
OUTPUT_DIR="${BUILDER_DIR}/output-dtb"
KERNEL_DIR="${BUILDER_DIR}/linux-6.18.33-dtb"
KERNEL_TARBALL="v6.18.33.tar.gz"
KERNEL_URL="https://github.com/unifreq/linux-6.18.y/archive/refs/tags/${KERNEL_TARBALL}"
PATCH_DIR="${BUILDER_DIR}/kernel-6.18"

mkdir -p "${OUTPUT_DIR}"

 echo "=== DTB-only: install minimal build deps ==="
apt-get update
apt-get install -y ca-certificates
apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates ccache curl device-tree-compiler \
  flex gcc-aarch64-linux-gnu git kmod libelf-dev libssl-dev make patch \
  python3 rsync tar wget xz-utils gzip

MAKE_ARGS=(ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)
KERNEL_JOBS="${KERNEL_JOBS:-8}"
echo "=== Kernel build parallel jobs: -j${KERNEL_JOBS} ==="
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_DIR="${CCACHE_DIR:-${BUILDER_DIR}/.ccache}"
  export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-3G}"
  mkdir -p "${CCACHE_DIR}"
  ccache -M "${CCACHE_MAXSIZE}" || true
  ccache -z || true
  MAKE_ARGS+=("CC=ccache aarch64-linux-gnu-gcc" "HOSTCC=ccache gcc")
fi

cd "${BUILDER_DIR}"
echo "=== DTB-only: fetch kernel ${KERNEL_TARBALL} ==="
if [ ! -d "${KERNEL_DIR}" ]; then
  wget -q --show-progress "${KERNEL_URL}" -O "/tmp/${KERNEL_TARBALL}"
  tar xf "/tmp/${KERNEL_TARBALL}" -C "${BUILDER_DIR}"
  rm -rf "${KERNEL_DIR}"
  mv "${BUILDER_DIR}/linux-6.18.y-6.18.33" "${KERNEL_DIR}"
  rm -f "/tmp/${KERNEL_TARBALL}"
fi

cd "${KERNEL_DIR}"
echo "=== DTB-only: kernel version ==="
head -5 Makefile

echo "=== DTB-only: applying patches ==="
if ls "${PATCH_DIR}"/*.patch >/dev/null 2>&1; then
  for patch_file in "${PATCH_DIR}"/*.patch; do
    echo "--- Applying: $(basename "${patch_file}") ---"
    body_file="$(mktemp)"
    sed -n '/^diff --git/,$p' "${patch_file}" > "${body_file}"
    if GIT_CEILING_DIRECTORIES="${BUILDER_DIR}" git apply --check "${patch_file}" 2>/dev/null; then
      GIT_CEILING_DIRECTORIES="${BUILDER_DIR}" git apply "${patch_file}"
      echo "  Applied via git apply (clean)"
    elif patch -p1 --fuzz=3 --no-backup-if-mismatch < "${body_file}" 2>&1; then
      echo "  Applied via patch -p1 (with fuzz=3)"
    else
      echo "  WARNING: Patch $(basename "${patch_file}") could NOT be applied; continuing for DTB-only build"
    fi
    rm -f "${body_file}"
  done
else
  echo "No patches found in ${PATCH_DIR}"
fi

echo "=== DTB-only: copying custom DTS ==="
shopt -s nullglob
for dts_file in "${PATCH_DIR}"/rk3399pro-neardi-linux-lc110*.dts; do
  dtb_name="$(basename "${dts_file%.dts}.dtb")"
  cp -v "${dts_file}" arch/arm64/boot/dts/rockchip/
  if ! grep -q "${dtb_name}" arch/arm64/boot/dts/rockchip/Makefile; then
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += ${dtb_name}" >> arch/arm64/boot/dts/rockchip/Makefile
  fi
done
shopt -u nullglob

echo "=== DTB-only: configuring kernel ==="
CUSTOM_CONFIG="${PATCH_DIR}/config-6.18"
if [ -f "${CUSTOM_CONFIG}" ]; then
  cp -a "${CUSTOM_CONFIG}" .config
else
  make "${MAKE_ARGS[@]}" defconfig
fi

# Keep same non-Rockchip disables as full build to avoid olddefconfig churn.
sed -i 's/^CONFIG_CLK_IMX8MM=y/# CONFIG_CLK_IMX8MM is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MN=y/# CONFIG_CLK_IMX8MN is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MP=y/# CONFIG_CLK_IMX8MP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8MQ=y/# CONFIG_CLK_IMX8MQ is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8QXP=y/# CONFIG_CLK_IMX8QXP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX8ULP=y/# CONFIG_CLK_IMX8ULP is not set/' .config
sed -i 's/^CONFIG_CLK_IMX93=y/# CONFIG_CLK_IMX93 is not set/' .config
make "${MAKE_ARGS[@]}" olddefconfig

echo "=== DTB-only: building dtbs ==="
make "${MAKE_ARGS[@]}" -j"${KERNEL_JOBS}" dtbs

echo "=== DTB-only: collecting RK3399 DTBs ==="
rm -rf dtbs
mkdir -p dtbs
find arch/arm64/boot/dts/rockchip -name "rk3399*.dtb" -exec cp {} dtbs/ \;
tar -zcvf "${OUTPUT_DIR}/dtbs.tar.gz" dtbs
sha256sum "${OUTPUT_DIR}/dtbs.tar.gz" | tee "${OUTPUT_DIR}/SHA256SUMS"
ls -alh "${OUTPUT_DIR}"
if command -v ccache >/dev/null 2>&1; then ccache -s || true; fi
echo "=== DTB-only build completed successfully! ==="
