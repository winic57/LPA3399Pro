#!/usr/bin/env bash
set -euo pipefail

TARGET_HOST=${TARGET_HOST:-192.168.50.113}
TARGET_USER=${TARGET_USER:-root}
TARGET_PASS=${TARGET_PASS:-1234}
TARGET="${TARGET_USER}@${TARGET_HOST}"

SSH=(sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 "${TARGET}")
SCP=(sshpass -p "${TARGET_PASS}" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

wait_ssh() {
  local i
  for i in $(seq 1 120); do
    if ping -c 1 -W 1 "${TARGET_HOST}" >/dev/null 2>&1 && "${SSH[@]}" 'echo READY' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "ERROR: ${TARGET_HOST} not reachable by SSH" >&2
  return 1
}

remote() {
  "${SSH[@]}" "$@"
}

echo "== wait for ${TARGET_HOST} SSH =="
wait_ssh

echo "== ensure target packages =="
remote 'apt-get update || true; apt-get install -y gpiod usbutils || true'

echo "== upload scripts =="
"${SCP[@]}" \
  "${ROOT_DIR}/tools/npu_powerctrl_gpiod.sh" \
  "${ROOT_DIR}/tools/npu_mainline_usb_ntb_boot.sh" \
  "${ROOT_DIR}/tools/npu_mainline_usb_ntb_check.sh" \
  "${ROOT_DIR}/configs/npu/npu_startup.sh" \
  "${TARGET}:/tmp/"

"${SCP[@]}" \
  "${ROOT_DIR}/configs/npu/npu_transfer_proxy.service" \
  "${ROOT_DIR}/configs/npu/npu-usb-workflow.env" \
  "${TARGET}:/tmp/"

echo "== install target files =="
remote '
set -e
install -m 0755 /tmp/npu_powerctrl_gpiod.sh /usr/local/bin/npu_powerctrl-gpiod
install -m 0755 /tmp/npu_mainline_usb_ntb_boot.sh /usr/local/bin/npu_mainline_usb_ntb_boot.sh
install -m 0755 /tmp/npu_mainline_usb_ntb_check.sh /usr/local/bin/npu_mainline_usb_ntb_check.sh
install -m 0755 /tmp/npu_startup.sh /usr/local/bin/npu_startup.sh
install -m 0644 /tmp/npu_transfer_proxy.service /etc/systemd/system/npu_transfer_proxy.service
install -m 0644 /tmp/npu-usb-workflow.env /etc/default/npu-usb-workflow
systemctl daemon-reload
'

echo "== optional operator hint =="
cat <<'EOF'
If you already know the vendor-equivalent GPIO init values, set them before restarting service, e.g.
  sed -i "s|^# NPU_INIT_GLOBAL_LINES=.*|NPU_INIT_GLOBAL_LINES=4=1,10=1,11=1,32=1,35=in,36=0,54=1,55=1,56=1|" /etc/default/npu-usb-workflow
For precise .129-like holder timing tests on .113, also consider:
  cat >> /etc/default/npu-usb-workflow <<CONF
NPU_PRECISE_POWERUP_PROFILE=golden129
GPIO_HOLD_SETTLE_MS=0
GPIO_HOLD_RELEASE_SETTLE_MS=0
NPU_PRECISE_POWER_GPIO_STAGE=before_low
NPU_PRECISE_HELPER_CMD=/usr/local/bin/npu_boot
NPU_PRECISE_HELPER_STAGE=after_stage1
CONF
If you need to mimic SDK `npu_upgrade` exactly, you can additionally set:
  echo 'WRITE_IMAGES_BEFORE_RS=1' >> /etc/default/npu-usb-workflow
WARNING: this enables vendor-style `upgrade_tool wl` before `rs`, which carries persistent NPU flash write risk.
For host-side PCIe re-train A/B (safe, but currently no positive .113 result yet), you can try:
  cat >> /etc/default/npu-usb-workflow <<CONF
PCIE_RESCAN_AFTER_POWER=1
PCIE_HOST_REBIND_AFTER_POWER=1
PCIE_HOST_REBIND_WAIT_SEC=5
CONF
and then restart the service again.
EOF

echo "== restart service and collect status =="
remote '
set -e
systemctl restart npu_transfer_proxy.service || true
sleep 3
systemctl status npu_transfer_proxy.service --no-pager -l || true
/usr/local/bin/npu_powerctrl-gpiod status || true
/usr/local/bin/npu_mainline_usb_ntb_check.sh || true
'

echo "== deploy done =="
