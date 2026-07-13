# Docker-ready netfilter modules (2026-07-13)

## Problem
ophub 6.18 kos lacked `ip_tables` / `iptable_nat` / `iptable_filter` because:

```text
# CONFIG_NETFILTER_XTABLES_LEGACY is not set
```

On Linux 6.18, `IP_NF_FILTER` / `IP_NF_NAT` / … **depend on** `IP_NF_IPTABLES_LEGACY`, which depends on `NETFILTER_XTABLES_LEGACY`. Without legacy tables, Docker cannot create NAT chains (`iptables -t nat -N DOCKER` fails).

## Fix (kernel config)
Both:

- `LPA3399Pro/kernel-6.18/config-6.18` (GHA ophub build)
- `amlogic-s9xxx-armbian/compile-kernel/tools/config/config-6.18`

now set:

```text
CONFIG_NETFILTER_XTABLES_LEGACY=y
CONFIG_IP_NF_IPTABLES_LEGACY=m
CONFIG_IP_NF_FILTER=m
CONFIG_IP_NF_NAT=m
CONFIG_IP_NF_MANGLE=m
CONFIG_IP_NF_RAW=m
CONFIG_IP6_NF_IPTABLES_LEGACY=m
CONFIG_IP6_NF_FILTER=m
CONFIG_IP6_NF_NAT=m
CONFIG_IP6_NF_MANGLE=m
CONFIG_IP6_NF_RAW=m
CONFIG_NETFILTER_XT_NAT=m
```

After GHA rebuild, `kos.tar.gz` should include e.g.:

- `ip_tables.ko`, `iptable_filter.ko`, `iptable_nat.ko`, `iptable_mangle.ko`, `iptable_raw.ko`
- `ip6_tables.ko`, `ip6table_*.ko`
- existing: `nf_nat.ko`, `x_tables.ko`, `xt_MASQUERADE.ko`, …

## Image packaging (amlogic lpa3399pro rootfs)
- `etc/modules-load.d/lpa-docker-netfilter.conf` — load tables at boot
- `etc/docker/daemon.json` — `data-root=/mnt/sdcard/docker`, `iptables: true`
- `docker.service.d/99-tf-data-root.conf` — only start when `/mnt/sdcard` mounted
- firstboot installs `docker.io` `docker-cli` `iptables` (+ bluez/gpiod)

## Board after new kernel deploy
```bash
# replace Image + kos, depmod, reboot
modprobe iptable_nat
iptables -t nat -L -n
# enable full docker iptables
sed -i 's/"iptables": false/"iptables": true/' /etc/docker/daemon.json
systemctl restart docker
docker run --rm -p 8080:80 nginx:alpine   # or hello-world
```

## Live .17 note (until new kos)
Current running kernel still lacks these modules; dockerd uses `"iptables": false` workaround. TF data-root works; bridge NAT incomplete until new modules installed.
