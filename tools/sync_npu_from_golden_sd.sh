#!/usr/bin/env bash
# Sync NPU runtime from a golden SD rootfs to a target rootfs (new amlogic image).
# Safe defaults: copy only; never touches bootloader partitions.
#
# Required env:
#   GOLDEN_ROOT  path to mounted golden rootfs (ro recommended)
#   TARGET_ROOT  path to target rootfs (/ for live system, or mounted new root)
# Optional:
#   MODE=min|recommended|full   default min
#   DRY_RUN=1
#   COPY_DTB=1                  also copy selected dtb names into TARGET_BOOT
#   TARGET_BOOT=/boot           used when COPY_DTB=1

set -euo pipefail

GOLDEN_ROOT=${GOLDEN_ROOT:-}
TARGET_ROOT=${TARGET_ROOT:-}
MODE=${MODE:-min}
DRY_RUN=${DRY_RUN:-0}
COPY_DTB=${COPY_DTB:-0}
TARGET_BOOT=${TARGET_BOOT:-$TARGET_ROOT/boot}

die() { echo "ERROR: $*" >&2; exit 2; }
need_dir() { [[ -d "$1" ]] || die "missing dir: $1"; }

[[ -n "$GOLDEN_ROOT" && -n "$TARGET_ROOT" ]] || die "set GOLDEN_ROOT and TARGET_ROOT"
need_dir "$GOLDEN_ROOT"
need_dir "$TARGET_ROOT"
[[ "$TARGET_ROOT" != "/" || "$(id -u)" -eq 0 ]] || die "TARGET_ROOT=/ requires root"

copy_path() {
  local rel=$1
  local src="$GOLDEN_ROOT$rel"
  local dst="$TARGET_ROOT$rel"
  if [[ ! -e "$src" ]]; then
    echo "SKIP missing on golden: $rel"
    return 0
  fi
  echo "COPY $rel"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    # preserve mode/timestamps; do not cross filesystem weirdness
    cp -a "$src"/. "$dst"/
  else
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

MIN_PATHS=(
  /usr/share/npu_fw_usb_ntb_noep
  /usr/bin/upgrade_tool
  /usr/bin/npu_transfer_proxy
  /usr/bin/npu_powerctrl
  /usr/bin/npu_powerctrl.vendor129
  /usr/bin/npu_upgrade
  /usr/bin/npu_upgrade_pcie
  /usr/bin/npu-image.sh
  /usr/local/bin/npu_boot
  /usr/local/bin/npu_startup.sh
  /usr/local/bin/npu_usb_ntb_noep_rknn.sh
  /usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh
  /usr/local/bin/npu_mainline_usb_ntb_boot.sh
  /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh
  /usr/local/bin/npu_mainline_usb_ntb_check.sh
  /usr/local/bin/npu_powerctrl-gpiod
  /usr/local/bin/npu_powerctrl_gpiod_vendor_wrapper.sh
  /usr/local/bin/npu_transfer_proxy_launcher.sh
  /usr/local/bin/npu_make_noep_ntb_boot.py
  /usr/local/bin/install_npu_usb_ntb_noep_profile.sh
  /usr/local/bin/npu_usb3_phy_role_snapshot.sh
  /usr/local/bin/npu_usb_precise_compare_collect.sh
  /etc/default/npu-usb-workflow
  /etc/systemd/system/npu_transfer_proxy.service
)

REC_EXTRA=(
  /usr/share/npu_fw_pcie
  /usr/share/npu_fw
)

FULL_EXTRA=(
  /usr/share/npu_fw_usb_ntb_pcie_deferred
  /usr/share/npu_fw_usb_ntb_pcie_deferred_29080426571
  /opt/rknn_py39
  /root/npu_deep_test
  /root/npu_deep_manual
)

PATHS=("${MIN_PATHS[@]}")
if [[ "$MODE" == "recommended" || "$MODE" == "full" ]]; then
  PATHS+=("${REC_EXTRA[@]}")
fi
if [[ "$MODE" == "full" ]]; then
  PATHS+=("${FULL_EXTRA[@]}")
fi

echo "GOLDEN_ROOT=$GOLDEN_ROOT"
echo "TARGET_ROOT=$TARGET_ROOT"
echo "MODE=$MODE DRY_RUN=$DRY_RUN"

for rel in "${PATHS[@]}"; do
  copy_path "$rel"
done

if [[ "$COPY_DTB" == "1" ]]; then
  need_dir "$TARGET_BOOT"
  # Prefer golden boot mount sibling if available via GOLDEN_BOOT
  GOLDEN_BOOT=${GOLDEN_BOOT:-}
  if [[ -z "$GOLDEN_BOOT" && -d "$(dirname "$GOLDEN_ROOT")/boot" ]]; then
    GOLDEN_BOOT="$(dirname "$GOLDEN_ROOT")/boot"
  fi
  [[ -n "$GOLDEN_BOOT" && -d "$GOLDEN_BOOT" ]] || die "COPY_DTB=1 needs GOLDEN_BOOT"
  mkdir -p "$TARGET_BOOT/dtb/rockchip"
  for f in \
    lpa3399pro-0030-pd-usb0otg.dtb \
    lpa3399pro-0030-pd-usb0p.dtb \
    lpa3399pro-0030-pd.dtb \
    lpa3399pro-0030-pd-usb0role.dtb \
    rk3399pro-neardi-linux-lc110-base.dtb
  do
    src="$GOLDEN_BOOT/dtb/rockchip/$f"
    if [[ -f "$src" ]]; then
      echo "COPY DTB $f"
      if [[ "$DRY_RUN" != "1" ]]; then
        cp -a "$src" "$TARGET_BOOT/dtb/rockchip/$f"
      fi
    else
      echo "SKIP DTB missing $f"
    fi
  done
  echo "NOTE: update extlinux/armbianEnv to use lpa3399pro-0030-pd-usb0otg.dtb if desired"
fi

if [[ "$DRY_RUN" != "1" && "$TARGET_ROOT" == "/" ]]; then
  chmod 0755 /usr/bin/upgrade_tool /usr/bin/npu_transfer_proxy 2>/dev/null || true
  chmod 0755 /usr/local/bin/npu_* /usr/local/bin/install_npu_usb_ntb_noep_profile.sh 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
fi

echo
echo "Done. Verify:"
echo "  ls -l \$TARGET_ROOT/usr/share/npu_fw_usb_ntb_noep/boot.img"
echo "  ls -l \$TARGET_ROOT/usr/bin/upgrade_tool \$TARGET_ROOT/usr/bin/npu_transfer_proxy"
