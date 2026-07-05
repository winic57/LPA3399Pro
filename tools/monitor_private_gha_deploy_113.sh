#!/usr/bin/env bash
set -euo pipefail

REPO=${REPO:-winic57/LPA3399Pro-private}
RUN_ID=${RUN_ID:-}
WORKFLOW=${WORKFLOW:-ophub_6.18.y.yml}
BRANCH=${BRANCH:-master}
TOKEN_FILE=${TOKEN_FILE:-/home/henry/.config/github/pat_lpa3399pro_private.txt}
PROXY=${PROXY:-http://192.168.50.62:7890}
BOARD=${BOARD:-192.168.50.113}
BOARD_PASS=${BOARD_PASS:-1234}
POLL_SEC=${POLL_SEC:-60}
MAX_WAIT_SEC=${MAX_WAIT_SEC:-14400}
START_NPU_TEST=${START_NPU_TEST:-1}
NPU_WRITE_IMAGES_BEFORE_RS=${NPU_WRITE_IMAGES_BEFORE_RS:-1}
NPU_POST_RS_WAIT_SEC=${NPU_POST_RS_WAIT_SEC:-8}
NPU_POWERCTRL=${NPU_POWERCTRL:-/usr/local/bin/npu_powerctrl-gpiod}
NPU_PRECISE_POWERUP_PROFILE=${NPU_PRECISE_POWERUP_PROFILE:-golden129}
TAG=${TAG:-private_deferred_$(date +%Y%m%d_%H%M%S)}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT_DIR=${OUT_DIR:-$ROOT/build_artifacts/${TAG}}
LOG=${LOG:-$ROOT/logs/${TAG}_monitor_deploy_verify.log}
mkdir -p "$OUT_DIR" "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1

ts(){ date '+[%F %T %Z]'; }
api(){
  local method=${1:-GET}; shift || true
  local url=$1; shift || true
  curl -fsSL --proxy "$PROXY" -X "$method" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/vnd.github+json' \
    "$@" "$url"
}
sshb(){ sshpass -p "$BOARD_PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@"$BOARD" "$@"; }
scpb(){ sshpass -p "$BOARD_PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$@"; }

TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")
if [ -z "$RUN_ID" ]; then
  RUN_ID=$(api GET "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW/runs?branch=$BRANCH&per_page=1" \
    | python3 -c 'import sys,json; j=json.load(sys.stdin); print(j["workflow_runs"][0]["id"] if j.get("workflow_runs") else "")')
fi
[ -n "$RUN_ID" ] || { echo "$(ts) ERROR: no RUN_ID"; exit 2; }

echo "$(ts) monitor start repo=$REPO workflow=$WORKFLOW run=$RUN_ID tag=$TAG out=$OUT_DIR"
start=$(date +%s)
while :; do
  tmp=$(mktemp)
  api GET "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID" > "$tmp"
  read -r status conclusion html head_sha < <(python3 - "$tmp" <<'PY'
import sys,json
r=json.load(open(sys.argv[1]))
print(r.get('status'), r.get('conclusion'), r.get('html_url'), r.get('head_sha','')[:12])
PY
  )
  rm -f "$tmp"
  echo "$(ts) run status=$status conclusion=$conclusion sha=$head_sha url=$html"
  if [ "$status" = completed ]; then
    [ "$conclusion" = success ] || exit 10
    break
  fi
  now=$(date +%s)
  if [ $((now-start)) -ge "$MAX_WAIT_SEC" ]; then
    echo "$(ts) ERROR: timeout waiting for run"
    exit 11
  fi
  sleep "$POLL_SEC"
done

# Download workflow artifact zip.
echo "$(ts) locating workflow artifact"
ART_URL=$(api GET "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts?per_page=20" \
  | python3 -c 'import sys,json; j=json.load(sys.stdin); arts=j.get("artifacts",[]); 
arts=[a for a in arts if not a.get("expired")];
sel=next((a for a in arts if a.get("name")=="ophub-kernel-6.18.33-artifacts"), arts[0] if arts else None);
print(sel["archive_download_url"] if sel else "")')
[ -n "$ART_URL" ] || { echo "$(ts) ERROR: no artifact url"; exit 12; }
ZIP="$OUT_DIR/artifact.zip"
echo "$(ts) downloading artifact zip"
curl -fL --proxy "$PROXY" -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.github+json' "$ART_URL" -o "$ZIP"
sha256sum "$ZIP" | tee "$OUT_DIR/sha256.txt"
rm -rf "$OUT_DIR/extract" "$OUT_DIR/dtbs_extract"
mkdir -p "$OUT_DIR/extract" "$OUT_DIR/dtbs_extract"
unzip -q "$ZIP" -d "$OUT_DIR/extract"
find "$OUT_DIR/extract" -maxdepth 2 -type f -printf '%p %s\n' | sort
IMG=$(find "$OUT_DIR/extract" -type f -name Image | head -1)
DTBS_TGZ=$(find "$OUT_DIR/extract" -type f -name 'dtbs.tar.gz' | head -1)
[ -s "$IMG" ] && [ -s "$DTBS_TGZ" ] || { echo "$(ts) ERROR: missing Image/dtbs.tar.gz"; exit 13; }
tar -xzf "$DTBS_TGZ" -C "$OUT_DIR/dtbs_extract"
DTB_DIR=$(find "$OUT_DIR/dtbs_extract" -type d -name dtbs | head -1)
[ -d "$DTB_DIR" ] || DTB_DIR="$OUT_DIR/dtbs_extract"
BASE_DTB=$(find "$DTB_DIR" -type f -name 'rk3399pro-neardi-linux-lc110-base-display.dtb' | head -1)
DEFER_DTB=$(find "$DTB_DIR" -type f -name 'rk3399pro-neardi-linux-lc110-pcie-deferred-display.dtb' | head -1)
[ -s "$BASE_DTB" ] && [ -s "$DEFER_DTB" ] || { echo "$(ts) ERROR: missing display dtbs"; exit 14; }
sha256sum "$IMG" "$BASE_DTB" "$DEFER_DTB" | tee -a "$OUT_DIR/sha256.txt"

# Optional offline sanity: DTB contains rockchip,deferred property in deferred variant.
if command -v dtc >/dev/null 2>&1; then
  dtc -I dtb -O dts "$DEFER_DTB" 2>/dev/null | grep -n 'rockchip,deferred\|pcie@f8000000' | head -20 || true
fi

REMOTE_DIR="/tmp/${TAG}"
echo "$(ts) copying artifacts to board $BOARD:$REMOTE_DIR"
sshb "rm -rf '$REMOTE_DIR'; mkdir -p '$REMOTE_DIR'"
scpb "$IMG" "$BASE_DTB" "$DEFER_DTB" root@"$BOARD":"$REMOTE_DIR/"

BASE_FN="rk3399pro-neardi-linux-lc110-base-display-${TAG}.dtb"
DEFER_FN="rk3399pro-neardi-linux-lc110-pcie-deferred-display-${TAG}.dtb"
REMOTE_SCRIPT=$(mktemp)
cat > "$REMOTE_SCRIPT" <<RS
set -euo pipefail
TAG='$TAG'
REMOTE_DIR='$REMOTE_DIR'
BASE_FN='$BASE_FN'
DEFER_FN='$DEFER_FN'
echo "REMOTE_DEPLOY_START \\$(date -Is)"
mountpoint -q /mnt/bootpart || mount /mnt/bootpart || true
BOOT=/mnt/bootpart
EXT=\$BOOT/extlinux/extlinux.conf
mkdir -p \$BOOT/extlinux \$BOOT/dtb/rockchip
cp -a \$EXT \$EXT.pre_\$TAG
if [ -e \$BOOT/Image ]; then cp -a \$BOOT/Image \$BOOT/Image.pre_\$TAG; fi
if [ -e \$BOOT/vmlinuz-6.18.33-rk35xx-ophub ]; then cp -a \$BOOT/vmlinuz-6.18.33-rk35xx-ophub \$BOOT/vmlinuz-6.18.33-rk35xx-ophub.pre_\$TAG; fi
install -m 0644 \$REMOTE_DIR/Image \$BOOT/Image
install -m 0644 \$REMOTE_DIR/Image \$BOOT/vmlinuz-6.18.33-rk35xx-ophub
install -m 0644 \$REMOTE_DIR/rk3399pro-neardi-linux-lc110-base-display.dtb \$BOOT/dtb/rockchip/\$BASE_FN
install -m 0644 \$REMOTE_DIR/rk3399pro-neardi-linux-lc110-pcie-deferred-display.dtb \$BOOT/dtb/rockchip/\$DEFER_FN
APPEND_LINE=\$(awk '/^  APPEND /{sub(/^  APPEND /,""); print; exit}' \$EXT)
[ -n "\$APPEND_LINE" ] || { echo 'missing APPEND in extlinux' >&2; exit 21; }
TMP=\$(mktemp)
{
  echo "DEFAULT private_deferred_display_\$TAG"
  echo "TIMEOUT 30"
  echo
  echo "LABEL private_deferred_display_\$TAG"
  echo "  LINUX /Image"
  echo "  FDT /dtb/rockchip/\$DEFER_FN"
  echo "  APPEND \$APPEND_LINE"
  echo
  echo "LABEL private_base_display_\$TAG"
  echo "  LINUX /Image"
  echo "  FDT /dtb/rockchip/\$BASE_FN"
  echo "  APPEND \$APPEND_LINE"
  echo
  awk 'NR>1 && !(/^DEFAULT /) && !(/^TIMEOUT /){print}' \$EXT
} > \$TMP
install -m 0644 \$TMP \$EXT
rm -f \$TMP
sync
sha256sum \$BOOT/Image \$BOOT/dtb/rockchip/\$BASE_FN \$BOOT/dtb/rockchip/\$DEFER_FN
head -40 \$EXT
rm -rf \$REMOTE_DIR
echo "REMOTE_DEPLOY_DONE \\$(date -Is)"
reboot
RS
scpb "$REMOTE_SCRIPT" root@"$BOARD":"$REMOTE_DIR/deploy.sh"
rm -f "$REMOTE_SCRIPT"
echo "$(ts) running remote deploy + reboot"
sshb "bash '$REMOTE_DIR/deploy.sh'" || true

echo "$(ts) waiting board ssh after reboot"
for i in $(seq 1 90); do
  sleep 5
  if sshb 'date -Is >/dev/null' 2>/dev/null; then echo "$(ts) ssh ready attempt=$i"; break; fi
  [ "$i" = 90 ] && { echo "$(ts) ERROR: ssh not ready"; exit 20; }
done

echo "$(ts) post-boot deferred baseline verify"
sshb 'set -x
 date -Is
 uname -a
 echo ===extlinux===; sed -n "1,28p" /mnt/bootpart/extlinux/extlinux.conf
 echo ===dt_property===; hexdump -C /sys/firmware/devicetree/base/pcie@f8000000/rockchip,deferred 2>/dev/null || true
 echo ===sysfs===; ls -l /sys/devices/platform/f8000000.pcie/pcie_deferred /sys/devices/platform/f8000000.pcie/pcie_reset_ep 2>&1 || true
 echo ===pcie_dev===; ls -l /dev/pcie-dev 2>&1 || true
 echo ===lspci===; lspci -nn || true
 echo ===dmesg_deferred===; dmesg | grep -Ei "rockchip-pcie|PCI host bridge|registered misc|deferred|pcie-dev" | tail -120 || true
 echo ===debugfs===; mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true; cat /sys/kernel/debug/pcie/pcie_trx 2>/dev/null || true
'

if [ "$START_NPU_TEST" = 1 ]; then
  echo "$(ts) NPU USB fw before pcie_deferred"
  sshb "set -x; for p in \$(pidof npu_transfer_proxy 2>/dev/null || true); do kill \$p || true; done; \
    NPU_POWERCTRL='$NPU_POWERCTRL' NPU_PRECISE_POWERUP_PROFILE='$NPU_PRECISE_POWERUP_PROFILE' \
    WRITE_IMAGES_BEFORE_RS='$NPU_WRITE_IMAGES_BEFORE_RS' START_PROXY=0 POST_RS_WAIT_SEC='$NPU_POST_RS_WAIT_SEC' RS_STRICT=0 \
    /usr/local/bin/npu_mainline_usb_ntb_boot.sh" || true
  echo "$(ts) trigger pcie_deferred + proxy"
  sshb 'set -x
    if [ -w /sys/devices/platform/f8000000.pcie/pcie_deferred ]; then echo 1 > /sys/devices/platform/f8000000.pcie/pcie_deferred; else echo no_pcie_deferred_sysfs; fi
    sleep 3
    lspci -nn || true
    /usr/local/bin/npu_transfer_proxy_launcher.sh || true
    sleep 2
    npu_transfer_proxy devices || true
    cat /sys/kernel/debug/pcie/pcie_trx 2>/dev/null || true
    dmesg | grep -Ei "rockchip-pcie|PCI host bridge|pcie-dev|dma|ntb|npu|2207|180a|1005" | tail -180 || true
  '
fi

echo "$(ts) COMPLETE log=$LOG out=$OUT_DIR"
