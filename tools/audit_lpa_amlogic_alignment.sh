#!/usr/bin/env bash
# Audit alignment between LPA3399Pro latest kernel artifacts and
# winic57/amlogic-s9xxx-armbian (local clone + optional release image).
#
# Usage:
#   tools/audit_lpa_amlogic_alignment.sh
#   LPA_ARTIFACT_DIR=.../pub7e98d1c_...0031... \
#   AMLOGIC_IMG=/tmp/lpa.img \
#   tools/audit_lpa_amlogic_alignment.sh
#
# Disk note: put large temporary extracts under /tmp (rootfs), not /mnt/sdb3.
# This script never writes multi-GB files to sdb3 unless OUT_DIR is overridden.

set -eu

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AMLOGIC_DIR=${AMLOGIC_DIR:-${ROOT_DIR}/lpa3399pro-armbian}
LPA_ARTIFACT_DIR=${LPA_ARTIFACT_DIR:-${ROOT_DIR}/build_artifacts/pub7e98d1c_run29013248531_0031_20260709_191258}
LPA_PATCH_DIR=${LPA_PATCH_DIR:-${ROOT_DIR}/kernel-6.18}
AMLOGIC_PATCH_DIR=${AMLOGIC_PATCH_DIR:-${AMLOGIC_DIR}/compile-kernel/tools/patch/common-kernel-patches}
AMLOGIC_PKG_DIR=${AMLOGIC_PKG_DIR:-${AMLOGIC_DIR}/kdevbuild/kernel-packages/rk35xx/6.18.33}
OUT_DIR=${OUT_DIR:-/tmp/lpa_amlogic_alignment_audit_$(date +%Y%m%d_%H%M%S)}
AMLOGIC_IMG=${AMLOGIC_IMG:-}
AMLOGIC_IMG_GZ=${AMLOGIC_IMG_GZ:-}
KEEP_TEMP=${KEEP_TEMP:-0}

MARKERS=(
  pcie_safe_retrain
  pcie_deferred
  pcie_reset_ep
  pcie_link_state
  npu_acm
  dma_start_once
  dma_timeout_ms
  dry_run
  failfast
  nfatal
)

mkdir -p "${OUT_DIR}"
REPORT="${OUT_DIR}/report.md"
exec > >(tee "${REPORT}") 2>&1

echo "# LPA3399Pro ↔ amlogic-s9xxx-armbian alignment audit"
echo
echo "- time: $(date -Is)"
echo "- ROOT_DIR: ${ROOT_DIR}"
echo "- LPA_ARTIFACT_DIR: ${LPA_ARTIFACT_DIR}"
echo "- AMLOGIC_DIR: ${AMLOGIC_DIR}"
echo "- OUT_DIR: ${OUT_DIR}"
echo

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 2; }; }
need sha256sum
need strings
need find
need awk

sha_short() { sha256sum "$1" | awk '{print substr($1,1,12)}'; }
file_size() { stat -c '%s' "$1" 2>/dev/null || echo 0; }

scan_markers() {
  local img=$1
  local label=$2
  echo "### markers: ${label}"
  echo
  echo "| marker | count |"
  echo "|---|---:|"
  if [[ ! -f "${img}" ]]; then
    echo "| (missing file) | - |"
    echo
    return
  fi
  local tmp
  tmp=$(mktemp)
  strings "${img}" >"${tmp}" || true
  local m c
  for m in "${MARKERS[@]}"; do
    c=$(grep -F -c -- "${m}" "${tmp}" 2>/dev/null || true)
    c=${c:-0}
    echo "| \`${m}\` | ${c} |"
  done
  rm -f "${tmp}"
  echo
  echo "- path: \`${img}\`"
  echo "- size: $(file_size "${img}") bytes"
  echo "- sha256: \`$(sha256sum "${img}" | awk '{print $1}')\`"
  echo
}

echo "## 1. Patch source alignment"
echo
if [[ -d "${LPA_PATCH_DIR}" && -d "${AMLOGIC_PATCH_DIR}" ]]; then
  mapfile -t lpa_patches < <(find "${LPA_PATCH_DIR}" -maxdepth 1 -type f -name '*.patch' | sort)
  mapfile -t arm_patches < <(find "${AMLOGIC_PATCH_DIR}" -maxdepth 1 -type f -name '*.patch' | sort)
  echo "- LPA patches: ${#lpa_patches[@]}"
  echo "- amlogic patches: ${#arm_patches[@]}"
  echo
  echo "| patch | LPA sha12 | amlogic sha12 | status |"
  echo "|---|---|---|---|"
  declare -A lpa_sha arm_sha
  for p in "${lpa_patches[@]}"; do
    b=$(basename "$p")
    lpa_sha["$b"]=$(sha_short "$p")
  done
  for p in "${arm_patches[@]}"; do
    b=$(basename "$p")
    arm_sha["$b"]=$(sha_short "$p")
  done
  # union of basenames
  {
    for k in "${!lpa_sha[@]}"; do echo "$k"; done
    for k in "${!arm_sha[@]}"; do echo "$k"; done
  } | sort -u | while read -r b; do
    ls=${lpa_sha[$b]:-MISSING}
    as=${arm_sha[$b]:-MISSING}
    st=DIFF
    [[ "$ls" == "$as" ]] && st=SAME
    [[ "$ls" == MISSING || "$as" == MISSING ]] && st=MISSING
    echo "| \`$b\` | \`${ls}\` | \`${as}\` | ${st} |"
  done
else
  echo "WARN: patch dirs missing"
fi
echo

echo "## 2. Local LPA artifact markers"
echo
LPA_IMAGE="${LPA_ARTIFACT_DIR}/Image"
scan_markers "${LPA_IMAGE}" "LPA artifact Image"

if [[ -f "${LPA_ARTIFACT_DIR}/SHA256SUMS" ]]; then
  echo "### LPA SHA256SUMS"
  echo '```'
  cat "${LPA_ARTIFACT_DIR}/SHA256SUMS"
  echo '```'
  echo
fi

echo "## 3. amlogic local kernel package markers"
echo
PKG_BOOT="${AMLOGIC_PKG_DIR}/boot-6.18.33-rk35xx-ophub.tar.gz"
if [[ -f "${PKG_BOOT}" ]]; then
  PKG_EXTRACT="${OUT_DIR}/amlogic_pkg"
  mkdir -p "${PKG_EXTRACT}"
  tar -xzf "${PKG_BOOT}" -C "${PKG_EXTRACT}"
  PKG_VML=$(find "${PKG_EXTRACT}" -type f \( -name 'vmlinuz-*' -o -name 'Image' \) | head -n1 || true)
  if [[ -n "${PKG_VML}" ]]; then
    scan_markers "${PKG_VML}" "amlogic kdevbuild package vmlinuz"
    if [[ -f "${LPA_IMAGE}" ]]; then
      if cmp -s "${LPA_IMAGE}" "${PKG_VML}"; then
        echo "- package vmlinuz vs LPA Image: **IDENTICAL**"
      else
        echo "- package vmlinuz vs LPA Image: **DIFFERENT**"
        echo "  - LPA: \`$(sha256sum "${LPA_IMAGE}" | awk '{print $1}')\`"
        echo "  - PKG: \`$(sha256sum "${PKG_VML}" | awk '{print $1}')\`"
      fi
      echo
    fi
  else
    echo "WARN: no vmlinuz/Image in package"
  fi
else
  echo "WARN: missing ${PKG_BOOT}"
fi
echo

echo "## 4. Optional release image audit"
echo
IMG_PATH=""
if [[ -n "${AMLOGIC_IMG}" && -f "${AMLOGIC_IMG}" ]]; then
  IMG_PATH="${AMLOGIC_IMG}"
elif [[ -n "${AMLOGIC_IMG_GZ}" && -f "${AMLOGIC_IMG_GZ}" ]]; then
  echo "- decompressing ${AMLOGIC_IMG_GZ} under ${OUT_DIR} ..."
  IMG_PATH="${OUT_DIR}/release.img"
  gzip -dc "${AMLOGIC_IMG_GZ}" >"${IMG_PATH}"
fi

if [[ -n "${IMG_PATH}" && -f "${IMG_PATH}" ]]; then
  echo "- image: \`${IMG_PATH}\` ($(file_size "${IMG_PATH}") bytes)"
  if ! command -v losetup >/dev/null || ! command -v sudo >/dev/null; then
    echo "WARN: losetup/sudo unavailable; skip boot extract"
  else
    LOOP=$(sudo losetup -f --show -P "${IMG_PATH}")
    echo "- loop: ${LOOP}"
    BOOT_MNT="${OUT_DIR}/bootmnt"
    mkdir -p "${BOOT_MNT}"
    # Prefer p1 as boot
    for part in "${LOOP}p1" "${LOOP}p2"; do
      [[ -b "${part}" ]] || continue
      if sudo mount -o ro "${part}" "${BOOT_MNT}" 2>/dev/null; then
        if [[ -f "${BOOT_MNT}/Image" || -f "${BOOT_MNT}/vmlinuz-6.18.33-rk35xx-ophub" || -d "${BOOT_MNT}/extlinux" ]]; then
          echo "- mounted boot-like partition: ${part}"
          break
        fi
        sudo umount "${BOOT_MNT}" || true
      fi
    done
    if mountpoint -q "${BOOT_MNT}"; then
      echo '```'
      ls -lah "${BOOT_MNT}" | head -40
      echo '```'
      CAND=""
      for f in \
        "${BOOT_MNT}/Image" \
        "${BOOT_MNT}/vmlinuz-6.18.33-rk35xx-ophub" \
        "${BOOT_MNT}/uImage"
      do
        [[ -f "$f" ]] && CAND=$f && break
      done
      if [[ -n "${CAND}" ]]; then
        cp -a "${CAND}" "${OUT_DIR}/image_boot_kernel.bin"
        scan_markers "${OUT_DIR}/image_boot_kernel.bin" "release image boot kernel ($(basename "${CAND}"))"
        if [[ -f "${LPA_IMAGE}" ]]; then
          if cmp -s "${LPA_IMAGE}" "${OUT_DIR}/image_boot_kernel.bin"; then
            echo "- release boot kernel vs LPA Image: **IDENTICAL**"
          else
            echo "- release boot kernel vs LPA Image: **DIFFERENT**"
          fi
          echo
        fi
      else
        echo "WARN: no Image/vmlinuz found in mounted boot partition"
      fi
      # NPU rootfs quick check on p2 if possible
      ROOT_MNT="${OUT_DIR}/rootmnt"
      mkdir -p "${ROOT_MNT}"
      for part in "${LOOP}p2" "${LOOP}p1"; do
        [[ -b "${part}" ]] || continue
        if sudo mount -o ro "${part}" "${ROOT_MNT}" 2>/dev/null; then
          if [[ -d "${ROOT_MNT}/usr" ]]; then
            echo "### release rootfs NPU path presence"
            echo
            for p in \
              /usr/local/bin/npu_usb_ntb_noep_rknn.sh \
              /usr/local/bin/npu_mainline_usb_ntb_boot.sh \
              /usr/local/bin/npu_powerctrl-gpiod \
              /usr/share/npu_fw_usb_ntb_noep/boot.img \
              /etc/default/npu-usb-workflow
            do
              if [[ -e "${ROOT_MNT}${p}" ]]; then
                echo "- PRESENT \`${p}\`"
              else
                echo "- MISSING  \`${p}\`"
              fi
            done
            echo
            sudo umount "${ROOT_MNT}" || true
            break
          fi
          sudo umount "${ROOT_MNT}" || true
        fi
      done
      sudo umount "${BOOT_MNT}" || true
    else
      echo "WARN: failed to mount boot partition"
    fi
    sudo losetup -d "${LOOP}" || true
  fi
else
  echo "- no AMLOGIC_IMG / AMLOGIC_IMG_GZ provided; skipped release image kernel extract."
  echo "- to audit a downloaded image:"
  echo '  ```bash'
  echo "  AMLOGIC_IMG_GZ=/tmp/xxx.img.gz ${0}"
  echo '  ```'
fi
echo

echo "## 5. Board rootfs packaging snapshot (amlogic tree)"
echo
BOARD_ROOTFS="${AMLOGIC_DIR}/build-armbian/armbian-files/different-files/lpa3399pro"
if [[ -d "${BOARD_ROOTFS}" ]]; then
  echo '```'
  find "${BOARD_ROOTFS}" -type f | sed "s|^${BOARD_ROOTFS}/||" | sort
  echo '```'
else
  echo "WARN: missing ${BOARD_ROOTFS}"
fi
echo

echo "## 6. Verdict helpers"
echo
echo "- If patch table is mostly SAME but package/image markers lack \`npu_acm\` / \`pcie_deferred\`, the image is built from **stale binary kernel**."
echo "- If LPA artifact has markers but lacks \`pcie_safe_retrain\`, artifact is pre-0044 (still OK for USB noep production path)."
echo "- For eMMC: prefer injecting latest LPA \`Image+dtbs+kos\` into amlogic Stage kernel / kdevbuild package before rebuild."
echo
echo "Report written to: ${REPORT}"

if [[ "${KEEP_TEMP}" != "1" ]]; then
  # keep report, drop heavy extracts
  rm -rf "${OUT_DIR}/amlogic_pkg" "${OUT_DIR}/bootmnt" "${OUT_DIR}/rootmnt" "${OUT_DIR}/release.img" 2>/dev/null || true
fi
