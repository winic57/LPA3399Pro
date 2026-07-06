#!/usr/bin/env bash
set -euo pipefail

OUT_DIR=${OUT_DIR:-/tmp/npu_usb_precise_$(hostname)_$(date +%Y%m%d_%H%M%S)}
READ_MMIO=${READ_MMIO:-0}
MMIO_WORDS=${MMIO_WORDS:-256}
DMESG_LINES=${DMESG_LINES:-600}
mkdir -p "$OUT_DIR"
exec > >(tee "$OUT_DIR/collect.log") 2>&1

section() { printf '\n===== %s =====\n' "$*"; }
run_file() { local name="$1"; shift; section "$name"; { echo "+ $*"; "$@"; } >"$OUT_DIR/$name.txt" 2>&1 || true; sed -n '1,220p' "$OUT_DIR/$name.txt"; }
copy_if() { local f="$1" dest; [ -e "$f" ] || return 0; dest="$OUT_DIR/files${f}"; mkdir -p "$(dirname "$dest")"; if [ -f "$f" ]; then cp -a "$f" "$dest" 2>/dev/null || cat "$f" > "$dest" 2>/dev/null || true; fi; }
cat_tree_files() { local root="$1" out="$2" maxd="${3:-3}"; [ -e "$root" ] || return 0; find "$root" -maxdepth "$maxd" -type f -print 2>/dev/null | sort | while read -r f; do echo "--- $f ---"; cat "$f" 2>&1 || true; done >"$OUT_DIR/$out" || true; }

section meta
{
  echo "OUT_DIR=$OUT_DIR"
  date -Is
  hostname || true
  uname -a
  cat /proc/cmdline 2>/dev/null || true
  cat /proc/uptime 2>/dev/null || true
} | tee "$OUT_DIR/meta.txt"

mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

run_file ip_addr ip -br addr
run_file ip_route ip route
run_file lsusb lsusb
run_file lsusb_tree lsusb -t
run_file upgrade_tool_ld upgrade_tool ld
run_file proxy_devices npu_transfer_proxy devices
run_file ps_npu pgrep -af 'npu|upgrade_tool|rknn|rockusb'
run_file systemctl_proxy systemctl status npu_transfer_proxy --no-pager -l

section files_hashes
{
  for p in /usr/bin/upgrade_tool /usr/bin/npu_transfer_proxy /usr/bin/npu_upgrade_pcie /usr/bin/npu-image.sh /usr/local/bin/npu-image.sh /usr/local/bin/npu_upgrade_pcie /usr/local/bin/npu_boot /usr/local/bin/npu_powerctrl-gpiod /usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh /etc/default/npu-usb-workflow; do
    [ -e "$p" ] || continue
    ls -l "$p"
    sha256sum "$p" 2>/dev/null || true
  done
  for d in /usr/share/npu_fw /usr/share/npu_fw_pcie /vendor/usr/share/npu_fw /root /userdata; do
    [ -d "$d" ] || continue
    echo "-- $d selected --"
    find "$d" -maxdepth 2 -type f \( -name 'MiniLoaderAll*.bin' -o -name 'uboot*.img' -o -name 'trust*.img' -o -name 'boot*.img' -o -name 'parameter.txt' -o -name 'npu*.sh' -o -name 'npu_upgrade*' \) -printf '%TY-%Tm-%Td %TH:%TM:%TS %s %p\n' 2>/dev/null | sort
    find "$d" -maxdepth 2 -type f \( -name 'MiniLoaderAll*.bin' -o -name 'uboot*.img' -o -name 'trust*.img' -o -name 'boot*.img' -o -name 'parameter.txt' -o -name 'npu*.sh' -o -name 'npu_upgrade*' \) -print0 2>/dev/null | xargs -0r sha256sum 2>/dev/null || true
  done
} | tee "$OUT_DIR/files_hashes.txt"

section scripts_head
for p in /usr/bin/npu-image.sh /usr/local/bin/npu-image.sh /usr/bin/npu_upgrade_pcie /usr/local/bin/npu_upgrade_pcie /usr/local/bin/npu_usb_loader_rs_rknn_pipeline.sh /etc/default/npu-usb-workflow; do
  [ -e "$p" ] || continue
  echo "--- $p ---" | tee -a "$OUT_DIR/scripts_head.txt"
  sed -n '1,220p' "$p" 2>&1 | tee -a "$OUT_DIR/scripts_head.txt" || true
done

section usb_sysfs
{
  for d in /sys/bus/platform/drivers/xhci-hcd /sys/bus/platform/drivers/dwc3 /sys/bus/platform/drivers/rockchip-dwc3 /sys/bus/platform/drivers/dwc3-of-simple /sys/bus/platform/drivers/ehci-platform /sys/bus/platform/drivers/ohci-platform; do
    [ -d "$d" ] || continue
    echo "--- $d ---"; ls -l "$d" 2>/dev/null || true
  done
  for d in /sys/bus/platform/devices/*usb* /sys/bus/platform/devices/*dwc3* /sys/bus/platform/devices/*phy* /sys/bus/platform/devices/*typec*; do
    [ -d "$d" ] || continue
    echo "--- $d ---"
    [ -L "$d/driver" ] && echo "driver=$(readlink -f "$d/driver")"
    for f in modalias of_node/name of_node/status of_node/dr_mode of_node/maximum-speed of_node/phys of_node/phy-names power/runtime_status power/control power/runtime_usage power/autosuspend_delay_ms current_dr_role role; do
      [ -e "$d/$f" ] && { printf '%s=' "$f"; tr -d '\000' < "$d/$f" 2>/dev/null || cat "$d/$f" 2>&1 || true; echo; }
    done
  done
  for d in /sys/bus/usb/devices/*; do
    [ -d "$d" ] || continue
    echo "--- $d ---"
    for f in busnum devnum devpath idVendor idProduct manufacturer product serial speed version bcdDevice authorized configuration rx_lanes tx_lanes; do
      [ -e "$d/$f" ] && { printf '%s=' "$f"; cat "$d/$f" 2>&1 || true; }
    done
    [ -L "$d/driver" ] && echo "driver=$(readlink -f "$d/driver")"
  done
} | tee "$OUT_DIR/usb_sysfs.txt"

section role_extcon_typec
{
  for d in /sys/class/extcon/* /sys/class/usb_role/* /sys/class/typec/*; do
    [ -e "$d" ] || continue
    echo "--- $d ---"
    find "$d" -maxdepth 3 -type f -print 2>/dev/null | sort | while read -r f; do printf '%s=' "$f"; cat "$f" 2>&1 || true; done
  done
} | tee "$OUT_DIR/role_extcon_typec.txt"

section debugfs_regdumps
{
  find /sys/kernel/debug -maxdepth 4 \( -name 'regdump' -o -name '*regs*' -o -name 'registers' \) -type f -print 2>/dev/null | sort | while read -r f; do
    echo "--- $f ---"
    cat "$f" 2>&1 | sed -n '1,260p' || true
  done
} | tee "$OUT_DIR/debugfs_regdumps.txt"

section clocks_regulators_gpio
{
  echo '--- clk_summary grep ---'
  grep -Ei 'usb|utmi|phy|dwc|otg|pcie|npu|wifi_pmu|rk808|clkout|grf|xin24' /sys/kernel/debug/clk/clk_summary 2>/dev/null | sed -n '1,320p' || true
  echo '--- regulator_summary grep ---'
  grep -Ei 'usb|utmi|phy|pcie|npu|wifi|vbus|vcc|3v3|1v8|rk808' /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | sed -n '1,260p' || true
  echo '--- gpio ---'
  cat /sys/kernel/debug/gpio 2>/dev/null || true
  echo '--- pinctrl grep ---'
  for f in /sys/kernel/debug/pinctrl/*/pinmux-pins /sys/kernel/debug/pinctrl/*/pinconf-pins; do [ -r "$f" ] && { echo "--- $f ---"; grep -Ei 'usb|typec|otg|pcie|npu|wifi|pmu|reset|vbus|gpio0|gpio1' "$f" || true; }; done
} | tee "$OUT_DIR/clocks_regulators_gpio.txt"

section proc_iomem
cat /proc/iomem 2>/dev/null | tee "$OUT_DIR/proc_iomem.txt" || true

if [ "$READ_MMIO" = 1 ]; then
  section mmio_dump
  python3 - "$OUT_DIR" "$MMIO_WORDS" <<'PY' | tee "$OUT_DIR/mmio_dump.txt" || true
import os, mmap, struct, sys
out=sys.argv[1]; words=int(sys.argv[2])
# Conservative read-only windows: PMU GRF, GRF, USB3 cores. Reads can still fail on strict devmem.
regions=[('pmugrf',0xff320000,0x1000),('grf',0xff770000,0x2000),('usb3_0',0xfe800000,0x1000),('usb3_1',0xfe900000,0x1000)]
try:
    fd=os.open('/dev/mem', os.O_RDONLY|os.O_SYNC)
except Exception as e:
    print('open /dev/mem failed',e); sys.exit(0)
ps=mmap.PAGESIZE
for name,base,size in regions:
    print(f'--- {name} 0x{base:x} size=0x{size:x} ---')
    n=min(size//4, words)
    try:
        off=base & ~(ps-1); delta=base-off; length=((delta+n*4+ps-1)//ps)*ps
        mm=mmap.mmap(fd,length,mmap.MAP_SHARED,mmap.PROT_READ,offset=off)
        for i in range(n):
            addr=base+i*4
            val=struct.unpack_from('<I', mm, delta+i*4)[0]
            print(f'0x{addr:08x}: 0x{val:08x}')
        mm.close()
    except Exception as e:
        print(f'ERR {name}: {e}')
os.close(fd)
PY
fi

section dmesg_tail
dmesg | grep -Ei 'usb|dwc3|xhci|ehci|ohci|2207|180a|0019|1005|firmware changed|SuperSpeed|high-speed|typec|role|extcon|phy|utmi|grf|npu|ntb|pcie|dma|error -71|disconnect|reset' | tail -n "$DMESG_LINES" | tee "$OUT_DIR/dmesg_usb_npu_tail.txt" || true

section pack
TAR="${OUT_DIR}.tar.gz"
tar -C "$(dirname "$OUT_DIR")" -czf "$TAR" "$(basename "$OUT_DIR")" 2>/dev/null || true
echo "TAR=$TAR"
