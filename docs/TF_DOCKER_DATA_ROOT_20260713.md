# .17 TF 数据盘 + Docker（对齐 .129）

## 参考 .129
- 数据盘挂载：`/mnt/sdcard`，`fstab` 带 **`nofail`**
- Docker：`data-root` 指向数据盘（.129 为 `/mnt/sdcard`）

## .17 实作（2026-07-13）

| 项 | 值 |
|---|---|
| 系统盘 | eMMC `mmcblk0` |
| TF | `mmcblk1` 整盘 1 分区 ext4 **LABEL=SDCARD** ~29G |
| 挂载点 | `/mnt/sdcard` |
| fstab | `UUID=… /mnt/sdcard ext4 defaults,nofail,noatime,x-systemd.device-timeout=8s,x-systemd.mount-timeout=10s 0 0` |
| Docker | `docker.io` 26.1.5 + `docker-cli` |
| data-root | **`/mnt/sdcard/docker`** |
| 应用数据建议 | `/mnt/sdcard/data` |

### 拔卡/坏卡仍能启动
1. `nofail`：挂载失败不阻塞 boot  
2. `docker.service` drop-in：`ConditionPathIsMountPoint=/mnt/sdcard` — 无卡时 **不启动 dockerd**（避免写到 eMMC 空目录）  
3. root/boot 全在 eMMC，与 TF 无关  

### 内核注意
当前 ophub 模块包 **缺 `ip_tables.ko` 等**，`CONFIG_NF_TABLES` 未开 → Docker 使用  
`"iptables": false` 才能启动。  
桥接 NAT 受限；容器默认网络可能需 host 网络或后续补全 netfilter 模块。  
`hello-world` 已验证通过。

### 验证
```bash
findmnt /mnt/sdcard
docker info | grep 'Docker Root Dir'
docker run --rm hello-world
```
