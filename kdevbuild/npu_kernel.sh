#!/usr/bin/env bash
set -euxo pipefail

WORKDIR=${WORKDIR:-$(pwd)}
SDK_DIR=${SDK_DIR:-${WORKDIR}/LPA3399Pro-SDK-Linux-V3.0}
NPU_DIR=${NPU_DIR:-${SDK_DIR}/npu}
RELEASE_DIR=${RELEASE_DIR:-${WORKDIR}/release-npu}
BUILD_TARGETS=${BUILD_TARGETS:-kernel}
NPU_BOARD_CONFIG=${NPU_BOARD_CONFIG:-device/rockchip/rk3399pro/BoardConfig-rk3399pro_npu-pcie.mk}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates cpio curl device-tree-compiler fakeroot file flex gawk \
  gcc-aarch64-linux-gnu git kmod libelf-dev liblz4-tool libncurses5-dev libssl-dev lzop make python python3 \
  python3-distutils rsync sudo tar u-boot-tools unzip wget xxd xz-utils zip zlib1g-dev

mkdir -p "${RELEASE_DIR}"
cd "${WORKDIR}"

if [ ! -d "${NPU_DIR}" ]; then
  if [ -n "${NPU_SDK_URL:-}" ]; then
    mkdir -p "${SDK_DIR}"
    tmp=/tmp/lpa3399pro-npu-sdk.tar
    curl -L --retry 3 -o "${tmp}" "${NPU_SDK_URL}"
    tar -xf "${tmp}" -C "${SDK_DIR}" --strip-components=1
  else
    echo "ERROR: ${NPU_DIR} not found. Set NPU_SDK_URL to a tarball containing the vendor SDK, or commit/provide LPA3399Pro-SDK-Linux-V3.0/npu." >&2
    exit 2
  fi
fi

test -x "${NPU_DIR}/build.sh" || chmod +x "${NPU_DIR}/build.sh"
cd "${NPU_DIR}"

# Select the RK3399Pro NPU PCIe board config explicitly; source tarballs may
# preserve an older .BoardConfig.mk symlink such as the USB profile.
if [ -n "${NPU_BOARD_CONFIG:-}" ]; then
  if [ -f "${NPU_BOARD_CONFIG}" ]; then
    ln -rfs "${NPU_BOARD_CONFIG}" device/rockchip/.BoardConfig.mk
  elif [ -f "device/rockchip/rk3399pro/${NPU_BOARD_CONFIG}" ]; then
    ln -rfs "device/rockchip/rk3399pro/${NPU_BOARD_CONFIG}" device/rockchip/.BoardConfig.mk
  else
    echo "ERROR: NPU_BOARD_CONFIG not found: ${NPU_BOARD_CONFIG}" >&2
    exit 4
  fi
  echo "Selected NPU board config: $(readlink -f device/rockchip/.BoardConfig.mk)"
fi

# Use distro cross compiler when the SDK prebuilt compiler is not packaged.
if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
  export CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
fi

# Apply repository-maintained NPU SDK patches. 0001 kept the earlier RNDIS
# experiment; later patches can supersede it (for mainline USB NTB, etc.).
PATCH_DIR="${WORKDIR}/patches/npu"
if [ -d "${PATCH_DIR}" ]; then
  for patch in "${PATCH_DIR}"/*.patch; do
    [ -e "${patch}" ] || continue
    echo "Applying NPU SDK patch: ${patch}"
    if git apply --check "${patch}"; then
      git apply "${patch}"
    elif patch -p1 --dry-run < "${patch}" >/dev/null; then
      patch -p1 < "${patch}"
    else
      echo "ERROR: failed to apply ${patch}" >&2
      exit 3
    fi
  done
fi

# If a later patch selects the official FunctionFS NTB/RKNN gadget path,
# remove the earlier RNDIS-only experiment from the final overlay. The RK3399Pro
# NPU firmware normally communicates with the host through npu_transfer_proxy,
# not by requiring a 192.168.180.8 RNDIS address.
if [ -f "buildroot/board/rockchip/rk3399pro_npu/fs-overlay-64/etc/init.d/.usb_config" ] &&    grep -q '^usb_ntb_en$' "buildroot/board/rockchip/rk3399pro_npu/fs-overlay-64/etc/init.d/.usb_config"; then
  rm -f "buildroot/board/rockchip/rk3399pro_npu/fs-overlay-64/etc/init.d/S51usb-rndis-ip"
fi

# The RK SDK build.sh reads device/rockchip/.BoardConfig.mk by default.
for target in ${BUILD_TARGETS}; do
  ./build.sh "${target}"
done

# Collect kernel and firmware artifacts when present.
find kernel -maxdepth 8 \( -name Image -o -name '*.dtb' -o -name '*.img' -o -name 'boot.img' -o -name '.config' -o -name 'System.map' \) \
  -type f -exec cp -av --parents {} "${RELEASE_DIR}/" \; || true
find rockdev -maxdepth 1 \( -name 'MiniLoaderAll.bin' -o -name 'parameter.txt' -o -name 'uboot.img' -o -name 'trust.img' -o -name 'boot.img' -o -name 'update.img' \) \
  -type f -o -type l | while read -r f; do cp -avL "$f" "${RELEASE_DIR}/"; done || true

(cd "${RELEASE_DIR}" && find . -type f -maxdepth 3 -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt) || true
ls -alh "${RELEASE_DIR}"
