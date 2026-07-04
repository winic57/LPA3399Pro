#!/usr/bin/env bash
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-192.168.50.113}
TARGET_USER=${TARGET_USER:-root}
TARGET_PASS=${TARGET_PASS:-1234}
TARGET="${TARGET_USER}@${TARGET_HOST}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR=${LOCAL_DIR:-${ROOT_DIR}/artifacts/golden129_npu_fw_20260704_224527}
REMOTE_DIR=${REMOTE_DIR:-/opt/npu_fw_profiles/golden129_usb_20260704}
REMOTE_LINK=${REMOTE_LINK:-/opt/npu_fw_profiles/golden129_usb_current}

SSH=(sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${TARGET}")
SCP=(sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

need_file() {
  [ -f "$1" ] || { echo "missing file: $1" >&2; exit 2; }
}

for f in MiniLoaderAll.bin boot.img parameter.txt trust.img uboot.img; do
  need_file "${LOCAL_DIR}/${f}"
done

echo "== create remote profile dir =="
"${SSH[@]}" "mkdir -p '${REMOTE_DIR}'"

echo "== upload golden129 usb profile =="
"${SCP[@]}" \
  "${LOCAL_DIR}/MiniLoaderAll.bin" \
  "${LOCAL_DIR}/boot.img" \
  "${LOCAL_DIR}/parameter.txt" \
  "${LOCAL_DIR}/trust.img" \
  "${LOCAL_DIR}/uboot.img" \
  "${TARGET}:${REMOTE_DIR}/"

echo "== install wrapper =="
"${SSH[@]}" <<EOS
set -e
ln -sfn '${REMOTE_DIR}' '${REMOTE_LINK}'
cat >/usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
set -a
[ -f /etc/default/npu-usb-workflow ] && . /etc/default/npu-usb-workflow
set +a
export FW_DIR=\${FW_DIR_OVERRIDE:-${REMOTE_LINK}}
export FW_PROFILE=\${FW_PROFILE_OVERRIDE:-normal}
export UBOOT_ADDR=\${UBOOT_ADDR_OVERRIDE:-0x20000}
export TRUST_ADDR=\${TRUST_ADDR_OVERRIDE:-0x20800}
export BOOT_ADDR=\${BOOT_ADDR_OVERRIDE:-0x21000}
export WRITE_IMAGES_BEFORE_RS=\${WRITE_IMAGES_BEFORE_RS_OVERRIDE:-0}
exec /usr/local/bin/npu_mainline_usb_ntb_boot.sh "\$@"
WRAP
chmod 0755 /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh
sha256sum '${REMOTE_DIR}'/* | sort
EOS

echo
echo "Installed:"
echo "  profile dir: ${REMOTE_DIR}"
echo "  profile link: ${REMOTE_LINK}"
echo "  wrapper: /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh"
echo
echo "Safe exact-.129 address test:"
echo "  /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh"
echo
echo "Safe guide-address A/B:"
echo "  UBOOT_ADDR_OVERRIDE=0x40000 TRUST_ADDR_OVERRIDE=0x40800 BOOT_ADDR_OVERRIDE=0x20000 /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh"
echo
echo "High-risk exact vendor path (persistent write risk, keep manual):"
echo "  WRITE_IMAGES_BEFORE_RS_OVERRIDE=1 /usr/local/bin/npu_mainline_usb_ntb_boot_golden129_usb.sh"
