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

## Related board-side already done (no reflash)
- WiFi: reset_gpio + rtw88 bring-up service
- DTB: bluetooth status=okay
- bluez userspace installed
