#!/bin/bash
# iter46 Step A 修正: 在 iter45 终态基础上, 只回退 GMAC 节点的 4 项改动
# 不动 iter5-13 期间禁用的 display-subsystem/sdhci/rkisp1/mipi-dphy/iep 等节点
# 不动 iter34 禁用的 pcie-phy/pcie/usbhost1
# 不动 iter35-37 的 ROOTFS 配置(NM unmanaged eth0 / fstrim disable / autologin 等)

set -e

SD_BOOT=/mnt/sdboot
DTB=$SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
ITER45_BACKUP=$SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter45_failed_20260616_183505
TS=$(date +%Y%m%d_%H%M%S)

echo "=== iter46 Step A 修正脚本 ==="
echo ""

# 1. 挂载 SD BOOT
sudo mount /dev/sdc1 $SD_BOOT
echo "已挂载 SD BOOT → $SD_BOOT"

# 2. 备份当前(factory DTB,导致 RCU stall)
sudo cp -v $DTB $SD_BOOT/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.iter46a_factory_broke_${TS}

# 3. 从 iter45 备份恢复(iter5-13 的禁用 + iter34-37 的 NM/autologin/fstrim 都保留在 ROOTFS,DTB 只是节点状态)
sudo cp -v $ITER45_BACKUP $DTB

# 4. 验证 iter45 基底已恢复
echo ""
echo "=== 当前 DTB(=iter45 基底)状态 ==="
echo "phy-mode = $(sudo fdtget $DTB /ethernet@fe300000 phy-mode)"
echo "assigned-clock-parents = $(sudo fdtget $DTB /ethernet@fe300000 assigned-clock-parents 2>&1)"
echo "snps,burst_len = $(sudo fdtget $DTB /ethernet@fe300000 snps,burst_len 2>&1)"

echo ""
echo "=== 现在 GMAC-only 回退(iter46-a 修正)==="

# (1) phy-mode: rgmii-id → rgmii (iter42 改回)
sudo fdtput -t s $DTB /ethernet@fe300000 phy-mode rgmii
echo "[1/5] phy-mode → rgmii  ✓"

# (2) 加回 assigned-clock-parents = <0x1a> (iter44 删错的)
sudo fdtput -t x $DTB /ethernet@fe300000 assigned-clock-parents 0x1a
echo "[2/5] assigned-clock-parents → 0x1a  ✓"

# (3) 删除 iter38 加的 snps,* 6 个属性
for p in snps,burst_len snps,pbl snps,rxpbl snps,txpbl snps,fixed-burst snps,force_thresh_dma_mode; do
    sudo fdtput -d $DTB /ethernet@fe300000 $p 2>/dev/null || true
done
echo "[3/5] 删除 iter38 snps,* 6 个属性  ✓"

# (4) 删除 iter43 加的 assigned-clock-rates
sudo fdtput -d $DTB /ethernet@fe300000 assigned-clock-rates 2>/dev/null || true
echo "[4/5] 删除 iter43 assigned-clock-rates  ✓"

# (5) iter45 加的额外 ahb reset → 回退到单一 SRST_A_GMAC
# 检查 iter45 终态 resets 值(应该是 <0x08 0x89 0x08 0x88> 或类似)
echo "[5/5] resets/reset-names 状态:"
sudo fdtget $DTB /ethernet@fe300000 resets
sudo fdtget $DTB /ethernet@fe300000 reset-names

# 如果 iter45 加了 ahb reset,撤销它
RESETS=$(sudo fdtget $DTB /ethernet@fe300000 resets 2>/dev/null)
if echo "$RESETS" | grep -q "0x88"; then
    # iter45 添加了 SRST_A_GMAC_NOC=0x88, 撤销回 <0x08 0x89>
    sudo fdtput -t x $DTB /ethernet@fe300000 resets 0x08 0x89
    sudo fdtput -t s $DTB /ethernet@fe300000 reset-names stmmaceth
    echo "  → 撤销 iter45 ahb reset, 恢复单一 SRST_A_GMAC=0x89/stmmaceth  ✓"
else
    echo "  → iter45 终态已是单一 reset,无需改动"
fi

echo ""
echo "=== 最终验证(GMAC 节点完整对照) ==="
echo "phy-mode              = $(sudo fdtget $DTB /ethernet@fe300000 phy-mode)         (期望: rgmii)"
echo "clock_in_out          = $(sudo fdtget $DTB /ethernet@fe300000 clock_in_out)         (期望: input)"
echo "tx_delay              = $(sudo fdtget $DTB /ethernet@fe300000 tx_delay)         (期望: 0x21=33)"
echo "rx_delay              = $(sudo fdtget $DTB /ethernet@fe300000 rx_delay)         (期望: 0x15=21)"
echo "snps,reset-gpio       = $(sudo fdtget $DTB /ethernet@fe300000 snps,reset-gpio)"
echo "snps,reset-delays-us  = $(sudo fdtget $DTB /ethernet@fe300000 snps,reset-delays-us)"
echo "assigned-clocks       = $(sudo fdtget $DTB /ethernet@fe300000 assigned-clocks)         (期望: 8 0xa6)"
echo "assigned-clock-parents= $(sudo fdtget $DTB /ethernet@fe300000 assigned-clock-parents)         (期望: 26)"
echo "resets                = $(sudo fdtget $DTB /ethernet@fe300000 resets)         (期望: 8 137 或 8 0x89)"
echo "reset-names           = $(sudo fdtget $DTB /ethernet@fe300000 reset-names)         (期望: stmmaceth)"
echo ""
echo "=== 不应存在的属性(已撤销) ==="
for p in snps,burst_len snps,pbl snps,rxpbl snps,txpbl snps,fixed-burst snps,force_thresh_dma_mode assigned-clock-rates; do
    val=$(sudo fdtget $DTB /ethernet@fe300000 $p 2>&1)
    if echo "$val" | grep -q "FDT_ERR_NOTFOUND"; then
        echo "  ✓ $p: 已不存在"
    else
        echo "  ✗ $p: 仍存在 = $val"
    fi
done

echo ""
echo "=== 同步 ROOTFS 副本 ==="
sudo mount /dev/sdc2 /mnt/sdroot
sudo cp -v $DTB /mnt/sdroot/usr/lib/lpa3399pro/rk3399pro-neardi-linux-lc110-base.dtb
sync

sudo umount /mnt/sdroot
sudo umount $SD_BOOT
echo ""
echo "=== iter46 Step A 修正完成, SD 卡可安全拔出 ==="
