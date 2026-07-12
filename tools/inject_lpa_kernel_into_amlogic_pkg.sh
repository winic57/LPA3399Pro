#!/usr/bin/env bash
# Inject latest LPA3399Pro kernel artifacts into amlogic-s9xxx-armbian
# ophub kernel package layout, so rebuild uses verified Image/dtbs/kos.
#
# Default source: local verified 0031 artifact dir.
# Does NOT push or trigger Actions; only rewrites local package files.
#
# Usage:
#   tools/inject_lpa_kernel_into_amlogic_pkg.sh
#   LPA_ARTIFACT_DIR=/path/to/Image+dtbs+kos tools/inject_lpa_kernel_into_amlogic_pkg.sh
#   DRY_RUN=1 tools/inject_lpa_kernel_into_amlogic_pkg.sh

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LPA_ARTIFACT_DIR=${LPA_ARTIFACT_DIR:-${ROOT_DIR}/build_artifacts/pub7e98d1c_run29013248531_0031_20260709_191258}
AMLOGIC_DIR=${AMLOGIC_DIR:-${ROOT_DIR}/lpa3399pro-armbian}
KERNEL_NAME=${KERNEL_NAME:-6.18.33-rk35xx-ophub}
PKG_DIR=${PKG_DIR:-${AMLOGIC_DIR}/kdevbuild/kernel-packages/rk35xx/6.18.33}
STAGE_DIR=${STAGE_DIR:-${AMLOGIC_DIR}/build-armbian/kernel/rk35xx/6.18.33}
WORK=${WORK:-/tmp/lpa_inject_kernel_$$}
DRY_RUN=${DRY_RUN:-0}
UPDATE_STAGE=${UPDATE_STAGE:-1}

need_file() { [[ -f "$1" ]] || { echo "ERROR: missing $1" >&2; exit 2; }; }

need_file "${LPA_ARTIFACT_DIR}/Image"
need_file "${LPA_ARTIFACT_DIR}/dtbs.tar.gz"
need_file "${LPA_ARTIFACT_DIR}/kos.tar.gz"

echo "LPA_ARTIFACT_DIR=${LPA_ARTIFACT_DIR}"
echo "PKG_DIR=${PKG_DIR}"
echo "STAGE_DIR=${STAGE_DIR}"
echo "KERNEL_NAME=${KERNEL_NAME}"
echo "DRY_RUN=${DRY_RUN}"

mkdir -p "${WORK}/boot" "${WORK}/dtb_pkg" "${WORK}/modules_root" "${WORK}/out"
cp -a "${LPA_ARTIFACT_DIR}/Image" "${WORK}/Image"
cp -a "${LPA_ARTIFACT_DIR}/dtbs.tar.gz" "${WORK}/dtbs.tar.gz"
cp -a "${LPA_ARTIFACT_DIR}/kos.tar.gz" "${WORK}/kos.tar.gz"

# boot package: vmlinuz + (optional empty placeholders if not present)
install -m 0644 "${WORK}/Image" "${WORK}/boot/vmlinuz-${KERNEL_NAME}"
# Keep config/System.map placeholders if package expects them
: >"${WORK}/boot/config-${KERNEL_NAME}"
: >"${WORK}/boot/System.map-${KERNEL_NAME}"

# dtb package
tar -xzf "${WORK}/dtbs.tar.gz" -C "${WORK}/dtb_pkg"
# normalize to dtb/rockchip/...
if [[ -d "${WORK}/dtb_pkg/rockchip" ]]; then
  mkdir -p "${WORK}/dtb/rockchip"
  cp -a "${WORK}/dtb_pkg/rockchip/." "${WORK}/dtb/rockchip/"
elif [[ -d "${WORK}/dtb_pkg/dtb/rockchip" ]]; then
  mkdir -p "${WORK}/dtb/rockchip"
  cp -a "${WORK}/dtb_pkg/dtb/rockchip/." "${WORK}/dtb/rockchip/"
else
  # flat dtbs
  mkdir -p "${WORK}/dtb/rockchip"
  find "${WORK}/dtb_pkg" -type f -name '*.dtb' -exec cp -a {} "${WORK}/dtb/rockchip/" \;
fi

# modules package: kos.tar.gz may be modules tree or raw .ko set
tar -xzf "${WORK}/kos.tar.gz" -C "${WORK}/modules_root"
MOD_OUT="${WORK}/modules"
mkdir -p "${MOD_OUT}"
if [[ -d "${WORK}/modules_root/lib/modules" ]]; then
  cp -a "${WORK}/modules_root/lib/modules/." "${MOD_OUT}/"
elif [[ -d "${WORK}/modules_root/modules" ]]; then
  cp -a "${WORK}/modules_root/modules/." "${MOD_OUT}/"
else
  # create synthetic modules dir for kernel name and drop kos under extra/
  mkdir -p "${MOD_OUT}/${KERNEL_NAME}/extra"
  find "${WORK}/modules_root" -type f -name '*.ko' -exec cp -a {} "${MOD_OUT}/${KERNEL_NAME}/extra/" \;
  # if a versioned dir already exists, prefer it
  verdir=$(find "${WORK}/modules_root" -type d -name '6.18.33*' | head -n1 || true)
  if [[ -n "${verdir}" ]]; then
    rm -rf "${MOD_OUT}"
    mkdir -p "${MOD_OUT}"
    parent=$(dirname "${verdir}")
    cp -a "${parent}/." "${MOD_OUT}/"
  fi
fi

BOOT_TGZ="${WORK}/out/boot-${KERNEL_NAME}.tar.gz"
DTB_TGZ="${WORK}/out/dtb-rockchip-${KERNEL_NAME}.tar.gz"
MOD_TGZ="${WORK}/out/modules-${KERNEL_NAME}.tar.gz"

tar -C "${WORK}/boot" -czf "${BOOT_TGZ}" .
tar -C "${WORK}" -czf "${DTB_TGZ}" dtb
tar -C "${MOD_OUT}" -czf "${MOD_TGZ}" .

(
  cd "${WORK}/out"
  sha256sum "boot-${KERNEL_NAME}.tar.gz" "dtb-rockchip-${KERNEL_NAME}.tar.gz" "modules-${KERNEL_NAME}.tar.gz" >sha256sums
)

echo "Built packages in ${WORK}/out:"
ls -lah "${WORK}/out"

install_pkg_set() {
  local dest=$1
  mkdir -p "${dest}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "DRY_RUN: would install into ${dest}"
    return
  fi
  # backup existing
  local bk
  bk="${dest}.bak_$(date +%Y%m%d_%H%M%S)"
  if [[ -d "${dest}" ]] && [[ -n "$(ls -A "${dest}" 2>/dev/null || true)" ]]; then
    mkdir -p "${bk}"
    cp -a "${dest}/." "${bk}/"
    echo "backup: ${bk}"
  fi
  cp -f "${BOOT_TGZ}" "${dest}/boot-${KERNEL_NAME}.tar.gz"
  cp -f "${DTB_TGZ}" "${dest}/dtb-rockchip-${KERNEL_NAME}.tar.gz"
  cp -f "${MOD_TGZ}" "${dest}/modules-${KERNEL_NAME}.tar.gz"
  cp -f "${WORK}/out/sha256sums" "${dest}/sha256sums"
  # keep old header package if present
  echo "installed into ${dest}"
  ls -lah "${dest}"
}

install_pkg_set "${PKG_DIR}"
if [[ "${UPDATE_STAGE}" == "1" ]]; then
  install_pkg_set "${STAGE_DIR}"
fi

# marker summary
echo
echo "Marker check on injected Image:"
for m in npu_acm pcie_deferred pcie_safe_retrain dma_start_once failfast dry_run; do
  c=$(strings "${WORK}/Image" | grep -F -c -- "$m" || true)
  printf '  %-20s %s\n' "$m" "$c"
done

echo
echo "Next steps:"
echo "  1) Optional: sync rootfs scripts per docs/AMLOGIC_ROOTFS_SYNC_LIST_20260712.md"
echo "  2) Commit/push amlogic-s9xxx-armbian OR run local rebuild"
echo "  3) Prefer also uploading Image/dtbs/kos to LPA public release so GHA Stage step pulls latest"
echo "  4) Audit: tools/audit_lpa_amlogic_alignment.sh"

if [[ "${DRY_RUN}" == "1" ]]; then
  echo "DRY_RUN complete; temp kept at ${WORK}"
else
  rm -rf "${WORK}"
fi
