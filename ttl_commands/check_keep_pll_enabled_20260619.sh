#!/bin/bash
# v4b-fix TTL diagnostic: check if motorcomm,keep-pll-enabled is applied
# Run on the board via TTL serial console as root
echo "=== 1. DT motorcomm,keep-pll-enabled ==="
find /proc/device-tree -name 'motorcomm,keep-pll-enabled' 2>/dev/null
echo "--- mdio node ---"
ls /proc/device-tree/ethernet@fe300000/mdio/ 2>/dev/null || echo "NO mdio node"
echo "--- phy node ---"
ls -la /proc/device-tree/ethernet@fe300000/mdio/ethernet-phy@0/ 2>/dev/null || echo "NO phy node"

echo "=== 2. PHY of_node ==="
ls /sys/bus/mdio/devices/ 2>/dev/null || echo "NO mdio devices"
for d in /sys/bus/mdio/devices/*; do
  [ -d "$d" ] || continue
  echo "--- $d ---"
  cat "$d/phy_id" 2>/dev/null || echo "  (no phy_id)"
  if [ -L "$d/of_node" ]; then
    echo "  of_node -> $(readlink -f "$d/of_node")"
  else
    echo "  of_node: NOT SET"
  fi
done

echo "=== 3. dmesg PHY ==="
dmesg | grep -iE 'yt8521|motorcomm|keep.pll|phy.*(init|attach|connect|config)' | head -20

echo "=== 4. PHY register read (via /dev/mem MDIO, DWMAC1000) ==="
python3 << 'PYEOF'
import mmap, os, time

GMAC_BASE = 0xfe300000
MII_ADDR  = 0x10
MII_DATA  = 0x14
GBUSY     = 0x01
GWRITE    = 0x02
CLK_CSR_MASK = 0x3C

fd = os.open('/dev/mem', os.O_RDWR)
mem = mmap.mmap(fd, 0x10000, offset=GMAC_BASE)

def rd(off):
    return int.from_bytes(mem[off:off+4], 'little')
def wr(off, val):
    mem[off:off+4] = val.to_bytes(4, 'little')
def wait_busy():
    for _ in range(2000):
        if not (rd(MII_ADDR) & GBUSY):
            return True
        time.sleep(0.001)
    return False
def mdio_read(phy, reg):
    clk = rd(MII_ADDR) & CLK_CSR_MASK
    if not wait_busy(): return None
    wr(MII_ADDR, clk | GBUSY | (reg << 6) | (phy << 11))
    if not wait_busy(): return None
    return rd(MII_DATA) & 0xFFFF
def mdio_write(phy, reg, val):
    clk = rd(MII_ADDR) & CLK_CSR_MASK
    if not wait_busy(): return False
    wr(MII_DATA, val)
    wr(MII_ADDR, clk | GBUSY | GWRITE | (reg << 6) | (phy << 11))
    return wait_busy()

cur = rd(MII_ADDR)
print(f"GMAC_MII_ADDR: 0x{cur:08x} (clk_csr=0x{(cur & CLK_CSR_MASK) >> 2:x})")

print("\nStandard PHY registers:")
for reg in [0x00, 0x01, 0x02, 0x03, 0x04, 0x05]:
    v = mdio_read(0, reg)
    print(f"  reg 0x{reg:02x} = 0x{v:04x}" if v is not None else f"  reg 0x{reg:02x} = FAILED")

print("\nYT8521 extended registers:")
if mdio_write(0, 0x1E, 0x000C):
    v = mdio_read(0, 0x1F)
    if v is not None:
        print(f"  CLOCK_GATING_REG (0xC) = 0x{v:04x}  bit12 RX_CLK_EN={(v>>12)&1} (0=always-output, 1=gated)")
    else: print("  CLOCK_GATING_REG: read FAILED")
else: print("  CLOCK_GATING_REG: write FAILED")

if mdio_write(0, 0x1E, 0x0027):
    v = mdio_read(0, 0x1F)
    if v is not None:
        print(f"  SLEEP_CONTROL1 (0x27) = 0x{v:04x}  bit15 SLEEP_SW={(v>>15)&1} (0=disabled, 1=enabled)")
    else: print("  SLEEP_CONTROL1: read FAILED")
else: print("  SLEEP_CONTROL1: write FAILED")

if mdio_write(0, 0x1E, 0xA001):
    v = mdio_read(0, 0x1F)
    if v is not None:
        print(f"  CHIP_CONFIG (0xA001) = 0x{v:04x}  mode_sel={v&0x7} (0=UTP_TO_RGMII)")
    else: print("  CHIP_CONFIG: read FAILED")

mem.close()
os.close(fd)
PYEOF

echo "=== 5. Result interpretation ==="
echo "DT: find finds motorcomm,keep-pll-enabled => property exists"
echo "of_node: symlink to .../ethernet-phy@0 => PHY linked to DT"
echo "CLOCK_GATING_REG bit12=0 => RX clock always output (keep-pll-enabled applied)"
echo "CLOCK_GATING_REG bit12=1 => RX clock gated (keep-pll-enabled NOT applied)"
