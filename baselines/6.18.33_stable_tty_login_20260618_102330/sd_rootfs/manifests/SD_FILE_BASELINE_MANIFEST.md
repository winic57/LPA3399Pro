# SD card file-level baseline manifest

## Block IDs
/dev/sdc1: LABEL="BOOT" UUID="955919d4-e37d-4c44-99d6-c0a5552f798c" BLOCK_SIZE="4096" TYPE="ext4" PARTLABEL="primary" PARTUUID="bd1cf4c1-4313-4797-88d2-745d74467271"
/dev/sdc2: LABEL="ROOTFS" UUID="d52f7f8b-fa0e-4c9f-a552-d6df4329ac87" BLOCK_SIZE="4096" TYPE="ext4" PARTLABEL="primary" PARTUUID="61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf"

## Boot files
538d01dfa8dd132816401d462b90575ff1c23c7a0d5b22c0b3afa852c0e4ccbe  /mnt/sdc_boot/extlinux/extlinux.conf.before_partuuid_20260618_085921
ccfe09b71e0688d440f9e0e804e45d63bd5b95ea5a772bf4c1e4efa9fbf91501  /mnt/sdc_boot/extlinux/extlinux.conf.before_maxcpus4_20260618_093300
50e9dc1419412dadd6ad4b2343ff918f0b06b880accdd6beba4a1a93758ff473  /mnt/sdc_boot/extlinux/extlinux.conf.before_plymouth_off_20260618_093828
2d359c850f6e10d512d3e4803b5df4f9a4e46ed5c9e8e99987f6ef6934bcb96f  /mnt/sdc_boot/extlinux/extlinux.conf
d26302754fd1969dc3bf09c12507c49cbea6cc22ae6c60f4d5f3a4ffe7d90e22  /mnt/sdc_boot/extlinux/extlinux.conf.bak
8e33f3364e22318740be373ec43a2675af40c9ad6cdedcb9d1e818ed43e08811  /mnt/sdc_boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.gmac_pcie_disabled.bak
0d1f35edfb68c0757e56ced04cc500a7d76ac8fd53c7926e94da2cf4d4451742  /mnt/sdc_boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.mainline_pre_disable.bak
d7b3b29688d4c80af309056d596a9d02fcfe3199374a41c845f9353da86c632e  /mnt/sdc_boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb.vendor.bak
9d2cd47c2e4ca3b3c1034fb792be1fdf8cbe0f2e11971fc9ff8f252de4d5f63a  /mnt/sdc_boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb

## extlinux.conf
LABEL Armbian
  LINUX /Image
  FDT /dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb
  APPEND root=PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf rootflags=data=writeback rw rootwait rootdelay=10 rootfstype=ext4 console=ttyS2,1500000 console=tty1 panic=0 usbcore.autosuspend=-1 initcall_blacklist=psci_checker printk.devkmsg=on log_buf_len=16M maxcpus=4 systemd.default_timeout_start_sec=20 plymouth.enable=0 net.ifnames=0

## DTB status (fdtget)
/ethernet@fe300000 status=disabled
/pcie@f8000000 status=okay
/display-subsystem status=disabled
/vop@ff8f0000 status=disabled
/vop@ff900000 status=disabled
/watchdog@ff848000 status=disabled
/serial@ff1a0000 status=okay

## ROOTFS fstab
PARTUUID=61ec8aeb-3d1a-48fa-a9da-54d744ed8bdf  /      ext4  defaults,noatime,nodiratime,commit=60,errors=remount-ro  0 1
UUID=955919d4-e37d-4c44-99d6-c0a5552f798c  /boot  ext4  defaults  0 2
tmpfs           /tmp     tmpfs    defaults,nosuid                                             0 0
