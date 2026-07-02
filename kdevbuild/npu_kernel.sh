#!/usr/bin/env bash
set -euxo pipefail

WORKDIR=${WORKDIR:-$(pwd)}
SDK_DIR=${SDK_DIR:-${WORKDIR}/LPA3399Pro-SDK-Linux-V3.0}
NPU_DIR=${NPU_DIR:-${SDK_DIR}/npu}
RELEASE_DIR=${RELEASE_DIR:-${WORKDIR}/release-npu}
BUILD_TARGETS=${BUILD_TARGETS:-kernel}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bc bison build-essential ca-certificates cpio curl device-tree-compiler fakeroot file flex gawk \
  gcc-aarch64-linux-gnu git kmod liblz4-tool libncurses5-dev libssl-dev lzop make python python3 \
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

# The RK SDK build.sh reads device/rockchip/.BoardConfig.mk by default.
for target in ${BUILD_TARGETS}; do
  ./build.sh "${target}"
done

# Collect kernel and firmware artifacts when present.
find kernel -maxdepth 5 \( -name Image -o -name '*.dtb' -o -name 'boot.img' -o -name '.config' -o -name 'System.map' \) \
  -type f -exec cp -av --parents {} "${RELEASE_DIR}/" \; || true
find rockdev -maxdepth 1 \( -name 'MiniLoaderAll.bin' -o -name 'parameter.txt' -o -name 'uboot.img' -o -name 'trust.img' -o -name 'boot.img' -o -name 'update.img' \) \
  -type f -o -type l | while read -r f; do cp -avL "$f" "${RELEASE_DIR}/"; done || true

(cd "${RELEASE_DIR}" && find . -type f -maxdepth 3 -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.txt) || true
ls -alh "${RELEASE_DIR}"
