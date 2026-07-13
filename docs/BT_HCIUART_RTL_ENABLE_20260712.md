# Enable CONFIG_BT_HCIUART_RTL + incremental deploy (2026-07-12)

## Policy
Subsequent image/kernel updates are applied by **SSH to the running board**
(`root@192.168.50.17`), **not** by rewriting the whole SD image.

## Kernel config change
File: `kernel-6.18/config-6.18`

```
- # CONFIG_BT_HCIUART_RTL is not set
+ CONFIG_BT_HCIUART_RTL=y
```

Also mirrored in amlogic compile-kernel tools config when present.

## Why
RTL8821CS BT is UART serdev (`realtek,rtl8821cs-bt`). Without HCIUART_RTL,
`hci_uart` lacks Realtek protocol; `hci0` may appear via userspace attach but
init times out and firmware `rtl_bt/rtl8821cs_fw.bin` is not loaded correctly.

## After GHA kernel artifact is ready (SSH deploy outline)
```bash
# on host: download boot-*.tar.gz modules-*.tar.gz from Actions/release
# on board:
ssh root@192.168.50.17
# backup
cp -a /boot/vmlinuz-$(uname -r) /boot/vmlinuz.bak.$(date +%Y%m%d%H%M%S) || true
# extract new Image/modules, keep rootfs and data
# ensure /lib/modules/$(uname -r) matches package name or symlink
# reboot
```

## DTB patch (2026-07-13)
The vendor DTB `rk3399pro-neardi-linux-lc110-base.dtb` ships with `serial@ff180000/bluetooth { status="disabled"; }`.
Patched on-board by decompile → sed line 891 → recompile:

```bash
dtc -I dtb -O dts /boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb > /tmp/neardi.dts
sed '891s/status = "disabled"/status = "okay"/' /tmp/neardi.dts > /tmp/neardi_bt.dts
dtc -I dts -O dtb -o /boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb /tmp/neardi_bt.dts
```

After reboot: `hci0 UP RUNNING`, BD `60:FB:00:7E:D2:35`, HCI 4.1, Manufacturer: Realtek.
Firmware used: `rtl_bt/rtl8821cs_fw.bin` + `rtl8821cs_config.bin` (already in linux-firmware).

## WiFi/BT bringup script
`/usr/local/sbin/lpa-wifi-bt-bringup.sh` updated 2026-07-13:
- Removes outdated comment about RTL not being in kernel
- Adds serdev bus kick before falling back to hciattach
- hciattach fallback retained for kernels with disabled DT node

## Board state (2026-07-13 after reboot)
- WiFi: wlan0 UP
- BT: hci0 UP RUNNING (RTL8821CS via serdev, bd=60:fb:00:7e:d2:35)
- Docker: NAT working, nginx:alpine port-published test passed
- 4G: usb0 UP (Quectel EC20)
