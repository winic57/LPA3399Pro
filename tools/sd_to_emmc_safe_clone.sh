#!/usr/bin/env bash
# Safe SD -> eMMC install for Neardi LPA3399Pro (Rockchip), run from build host.
#
# IMPORTANT: Do NOT full-disk dd a live SD rootfs onto eMMC while booted from that
# SD — the kernel often stalls in D-state reading busy root blocks. This script
# uses a hybrid method:
#   1) Backup entire eMMC (compressed stream) to host
#   2) Copy Rockchip loader sectors + GPT layout from SD
#   3) Copy BOOT partition; rsync live root -> eMMC root (with excludes)
#   4) Randomize eMMC PARTUUID + filesystem UUIDs; rewrite extlinux/fstab
#   5) Grow eMMC root partition to media end
#
# Usage:
#   tools/sd_to_emmc_safe_clone.sh status
#   tools/sd_to_emmc_safe_clone.sh backup
#   tools/sd_to_emmc_safe_clone.sh clone          # backup + install
#   tools/sd_to_emmc_safe_clone.sh clone --yes
#   tools/sd_to_emmc_safe_clone.sh restore-emmc BACKUP.img.gz
#
# Env:
#   BOARD=192.168.50.17 PASS=1234
#   BACKUP_DIR=/mnt/sdb3/LPA3399Pro/backups/emmc_clone
#   SD_DEV=mmcblk1 EMMC_DEV=mmcblk0
#   SKIP_SD_BACKUP=1 BS=4M
set -euo pipefail

BOARD="${BOARD:-192.168.50.17}"
PASS="${PASS:-1234}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/sdb3/LPA3399Pro/backups/emmc_clone}"
SD_DEV="${SD_DEV:-mmcblk1}"
EMMC_DEV="${EMMC_DEV:-mmcblk0}"
BS="${BS:-4M}"
SKIP_SD_BACKUP="${SKIP_SD_BACKUP:-1}"
YES="${YES:-0}"
COMPRESS="${COMPRESS:-pigz}"
TAG="${TAG:-$(date +%Y%m%d_%H%M%S)}"
LOG="${LOG:-$BACKUP_DIR/run_${TAG}.log}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 -o ServerAliveInterval=30)

die() { echo "ERROR: $*" >&2; exit 2; }
info() { echo "[$(date +%H:%M:%S)] $*"; }

need_host() {
  command -v sshpass >/dev/null || die "need sshpass"
  mkdir -p "$BACKUP_DIR"
}

ssh_root() {
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@${BOARD}" "$@"
}

host_compress_cmd() {
  case "$COMPRESS" in
    pigz) command -v pigz >/dev/null && echo pigz || echo gzip ;;
    gzip) echo gzip ;;
    none) echo cat ;;
    *) die "COMPRESS must be pigz|gzip|none" ;;
  esac
}

ext_for_compress() {
  case "$(host_compress_cmd)" in
    pigz|gzip) echo img.gz ;;
    cat) echo img ;;
  esac
}

preflight() {
  info "preflight board=$BOARD sd=$SD_DEV emmc=$EMMC_DEV"
  ssh_root "echo UP; uname -a; findmnt -n -o SOURCE /; findmnt -n -o SOURCE /boot || true"
  local root_src
  root_src="$(ssh_root "findmnt -n -o SOURCE /")"
  [[ "$root_src" == *"${SD_DEV}p2"* ]] || die "root is '$root_src' — must boot from ${SD_DEV}p2"
  ssh_root "findmnt /dev/${EMMC_DEV} >/dev/null 2>&1 && exit 9 || exit 0" || die "eMMC has mounts — unmount first"
  local sd_b em_b free_b
  sd_b="$(ssh_root "blockdev --getsize64 /dev/${SD_DEV}")"
  em_b="$(ssh_root "blockdev --getsize64 /dev/${EMMC_DEV}")"
  info "SD=${sd_b} eMMC=${em_b}"
  (( em_b >= sd_b * 90 / 100 )) || die "eMMC much smaller than SD; refuse"
  free_b="$(df -B1 --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ')"
  (( free_b > sd_b / 4 )) || die "low backup free space: $free_b"
  info "preflight OK free=$free_b"
}

backup_dev() {
  local dev="$1" name="$2"
  local ext out ccmd lsz rsha
  ext="$(ext_for_compress)"
  out="${BACKUP_DIR}/${name}_${TAG}.${ext}"
  ccmd="$(host_compress_cmd)"
  info "backup /dev/${dev} -> $out ($ccmd)"
  set +e
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@${BOARD}" \
    "dd if=/dev/${dev} bs=${BS} status=progress 2>/tmp/dd_${name}.err" \
    | "$ccmd" -c >"$out"
  local rc=${PIPESTATUS[0]}
  set -e
  [[ $rc -eq 0 ]] || die "remote dd failed for $dev rc=$rc"
  [[ -s "$out" ]] || die "empty backup $out"
  rsha="$(ssh_root "dd if=/dev/${dev} bs=1M count=16 2>/dev/null | sha256sum | awk '{print \$1}'")"
  lsz="$(stat -c%s "$out")"
  {
    echo "device_head16M_sha256=${rsha}"
    echo "backup_path=${out}"
    echo "backup_bytes=${lsz}"
    echo "device_bytes=$(ssh_root "blockdev --getsize64 /dev/${dev}")"
  } | tee "${out}.meta"
  info "backup done ($lsz bytes)"
  echo "$out"
}

status_cmd() {
  need_host
  ssh_root "lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTUUID; echo; cat /proc/cmdline; echo; findmnt /; findmnt /boot; echo; parted /dev/${EMMC_DEV} print 2>/dev/null; parted /dev/${SD_DEV} print 2>/dev/null"
  ls -lah "$BACKUP_DIR" 2>/dev/null | tail -25 || true
}

confirm_clone() {
  [[ "$YES" == "1" ]] && return 0
  echo
  echo "Will OVERWRITE /dev/${EMMC_DEV} on ${BOARD} with hybrid clone of live SD (${SD_DEV})."
  echo "Vendor eMMC partitions will be replaced by Armbian 2-part layout."
  echo "Backup dir: $BACKUP_DIR"
  read -r -p "Type YES to continue: " ans
  [[ "$ans" == "YES" ]] || die "aborted"
}

# Hybrid install runs entirely on the board (except prior backup stream).
hybrid_install() {
  info "hybrid install on board: loaders + boot dd + root rsync + UUID fix"
  sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@${BOARD}" \
    "SD_DEV=${SD_DEV} EMMC_DEV=${EMMC_DEV} bash -s" <<'EOS'
set -euo pipefail
: "${SD_DEV:?}" "${EMMC_DEV:?}"
SD=/dev/${SD_DEV}
EM=/dev/${EMMC_DEV}
export DEBIAN_FRONTEND=noninteractive

findmnt -n -o SOURCE / | grep -q "${SD_DEV}p2"

for p in ${EM}p1 ${EM}p2 ${EM}p6; do umount "$p" 2>/dev/null || true; done
umount /mnt/emmc_boot /mnt/emmc_root 2>/dev/null || true

# packages
command -v sgdisk >/dev/null || apt-get install -y -qq gdisk >/dev/null
command -v rsync >/dev/null || apt-get install -y -qq rsync >/dev/null
command -v parted >/dev/null
command -v resize2fs >/dev/null

echo "=== 1) recreate GPT like SD (2 partitions) ==="
# Wipe secondary GPT area lightly then clone partition table via sgdisk
sgdisk --backup=/tmp/sd_gpt.bak "$SD"
# Zap eMMC and load SD table
sgdisk --zap-all "$EM" || true
sgdisk --load-backup=/tmp/sd_gpt.bak "$EM"
sgdisk -e "$EM" || true
# Randomize GUIDs immediately so we never share PARTUUID with SD
sgdisk -G "$EM"
partprobe "$EM" || true
sleep 1

# Ensure partition nodes exist
[[ -b ${EM}p1 && -b ${EM}p2 ]] || { echo "missing eMMC partitions after GPT clone"; parted -s "$EM" print; exit 3; }

echo "=== 2) Rockchip loaders from SD (before partition1) ==="
# Copy from sector 0 through start of p1 (includes GPT + idbloader/uboot/trust)
P1_START_S=$(parted -s "$EM" unit s print | awk '/^ 1 /{gsub(/s/,"",$2); print $2; exit}')
[[ -n "$P1_START_S" ]] || P1_START_S=32768
# Don't overwrite primary GPT header carelessly: copy loaders at known offsets
dd if="$SD" of="$EM" bs=512 skip=64 seek=64 count=16320 conv=notrunc,fsync status=none
dd if="$SD" of="$EM" bs=512 skip=16384 seek=16384 count=8192 conv=notrunc,fsync status=none
dd if="$SD" of="$EM" bs=512 skip=24576 seek=24576 count=8192 conv=notrunc,fsync status=none
# rewrite backup GPT to end after loader copy
sgdisk -e "$EM" || true
partprobe "$EM" || true

echo "=== 3) format partitions ==="
mkfs.ext4 -F -L BOOT ${EM}p1
mkfs.ext4 -F -L ROOTFS ${EM}p2

echo "=== 4) rsync live system ==="
mkdir -p /mnt/emmc_boot /mnt/emmc_root
mount ${EM}p1 /mnt/emmc_boot
mount ${EM}p2 /mnt/emmc_root
rsync -aHAX --delete \
  --exclude=/dev/** \
  --exclude=/proc/** \
  --exclude=/sys/** \
  --exclude=/tmp/** \
  --exclude=/run/** \
  --exclude=/mnt/** \
  --exclude=/media/** \
  --exclude=/lost+found \
  --exclude=/boot/** \
  / /mnt/emmc_root/
mkdir -p /mnt/emmc_root/{dev,proc,sys,tmp,run,mnt,media,boot}
chmod 1777 /mnt/emmc_root/tmp
rsync -aHAX --delete /boot/ /mnt/emmc_boot/

echo "=== 5) grow root to end of eMMC ==="
umount /mnt/emmc_boot
umount /mnt/emmc_root
sgdisk -e "$EM" || true
parted -s "$EM" resizepart 2 100%
partprobe "$EM" || true
sleep 1
e2fsck -f -y ${EM}p2 || true
resize2fs ${EM}p2

echo "=== 6) unique FS UUIDs + boot config ==="
e2fsck -f -y ${EM}p1 || true
e2fsck -f -y ${EM}p2 || true
tune2fs -U random ${EM}p1
tune2fs -U random ${EM}p2
BOOT_UUID=$(blkid -s UUID -o value ${EM}p1)
ROOT_UUID=$(blkid -s UUID -o value ${EM}p2)
PARTUUID=$(blkid -s PARTUUID -o value ${EM}p2)
[[ -n "$PARTUUID" && -n "$ROOT_UUID" && -n "$BOOT_UUID" ]]

mount ${EM}p1 /mnt/emmc_boot
mount ${EM}p2 /mnt/emmc_root
for f in /mnt/emmc_boot/extlinux/extlinux.conf /mnt/emmc_boot/armbianEnv.txt; do
  [[ -f $f ]] || continue
  cp -a "$f" "${f}.pre_emmc_clone"
  sed -i -E "s/root=PARTUUID=[^ ]+/root=PARTUUID=${PARTUUID}/g" "$f"
  sed -i -E "s|^rootdev=.*|rootdev=PARTUUID=${PARTUUID}|g" "$f"
done
grep -q 'maxcpus=4' /mnt/emmc_boot/extlinux/extlinux.conf 2>/dev/null || \
  sed -i 's/APPEND \(.*\)$/APPEND \1 maxcpus=4/' /mnt/emmc_boot/extlinux/extlinux.conf || true

cat > /mnt/emmc_root/etc/fstab <<FST
UUID=${ROOT_UUID}  /  ext4  defaults,noatime,nodiratime,commit=600,errors=remount-ro  0 1
UUID=${BOOT_UUID}  /boot  ext4  defaults  0 2
tmpfs           /tmp     tmpfs    defaults,nosuid                                             0 0
FST
mkdir -p /mnt/emmc_root/root /mnt/emmc_root/var/lib/lpa3399pro
echo no > /mnt/emmc_root/root/.no_rootfs_resize
cat > /mnt/emmc_root/var/lib/lpa3399pro/emmc_clone_stamp <<ST
date=$(date -Is)
method=hybrid_gpt_rsync
source=${SD_DEV}
target=${EMMC_DEV}
root_partuuid=${PARTUUID}
root_uuid=${ROOT_UUID}
boot_uuid=${BOOT_UUID}
ST

# sanity
test -e /mnt/emmc_boot/Image -o -e /mnt/emmc_boot/vmlinuz-6.18.33-rk35xx-ophub
test -e /mnt/emmc_root/usr/lib/systemd/systemd -o -x /mnt/emmc_root/sbin/init
test -d /mnt/emmc_root/lib/modules

sync
umount /mnt/emmc_root
umount /mnt/emmc_boot

# verify loaders
python3 - <<'PY'
import os
fd=os.open('/dev/mmcblk0', os.O_RDONLY)
for off,name in [(64,'idb'),(16384,'uboot'),(24576,'trust')]:
    os.lseek(fd, off*512, os.SEEK_SET)
    b=os.read(fd,8)
    print(name, b.hex(), 'OK' if any(b) else 'EMPTY')
os.close(fd)
PY

echo "=== final ==="
parted -s "$EM" unit MiB print
blkid ${EM}p1 ${EM}p2
echo "HYBRID_OK PARTUUID=${PARTUUID}"
EOS
}

restore_emmc() {
  local bak="${1:-}"
  [[ -n "$bak" && -f "$bak" ]] || die "usage: $0 restore-emmc FILE.img.gz"
  need_host
  preflight
  if [[ "$YES" != "1" ]]; then
    echo "Restore $bak -> /dev/${EMMC_DEV} (DESTROYS eMMC)"
    read -r -p "Type YES: " ans
    [[ "$ans" == "YES" ]] || die "aborted"
  fi
  info "streaming restore $bak"
  case "$bak" in
    *.gz) gzip -dc "$bak" ;;
    *) cat "$bak" ;;
  esac | sshpass -p "$PASS" ssh "${SSH_OPTS[@]}" "root@${BOARD}" \
    "dd of=/dev/${EMMC_DEV} bs=${BS} status=progress conv=fsync"
  ssh_root "sync; sgdisk -e /dev/${EMMC_DEV} 2>/dev/null || true; partprobe /dev/${EMMC_DEV} || true"
  info "restore done"
}

cmd_backup() {
  need_host
  preflight
  exec > >(tee -a "$LOG") 2>&1
  info "=== backup $TAG ==="
  backup_dev "$EMMC_DEV" "emmc_${EMMC_DEV}"
  [[ "$SKIP_SD_BACKUP" == "1" ]] || backup_dev "$SD_DEV" "sd_${SD_DEV}"
  ssh_root "lsblk; parted /dev/${EMMC_DEV} print; parted /dev/${SD_DEV} print; cat /proc/cmdline" \
    >"${BACKUP_DIR}/inventory_${TAG}.txt" || true
  info "=== backup complete ==="
  ls -lah "$BACKUP_DIR"/*"${TAG}"* 2>/dev/null || true
}

cmd_clone() {
  need_host
  preflight
  exec > >(tee -a "$LOG") 2>&1
  info "=== clone $TAG ==="
  confirm_clone
  backup_dev "$EMMC_DEV" "emmc_${EMMC_DEV}"
  [[ "$SKIP_SD_BACKUP" == "1" ]] || backup_dev "$SD_DEV" "sd_${SD_DEV}"
  ssh_root "lsblk; parted /dev/${EMMC_DEV} print; parted /dev/${SD_DEV} print" \
    >"${BACKUP_DIR}/inventory_pre_${TAG}.txt" || true
  hybrid_install
  ssh_root "lsblk; parted /dev/${EMMC_DEV} unit MiB print; blkid /dev/${EMMC_DEV}p1 /dev/${EMMC_DEV}p2" \
    | tee "${BACKUP_DIR}/inventory_post_${TAG}.txt"
  cat <<EOF

=== CLONE FINISHED (hybrid) ===
eMMC has Armbian 2-partition layout from live SD.
PARTUUID/UUIDs are unique to eMMC.
SD card unchanged.

Next:
  1) poweroff
  2) REMOVE SD card
  3) power on (boot from eMMC)
  4) if fail: insert SD, boot, restore:
       $0 restore-emmc ${BACKUP_DIR}/emmc_${EMMC_DEV}_${TAG}.$(ext_for_compress)

Log: $LOG
Backup: $BACKUP_DIR
EOF
}

usage() {
  cat <<EOF
Usage: $0 {status|backup|clone|restore-emmc} [--yes]

  status              show disks
  backup              backup eMMC to host (optional SD)
  clone               backup eMMC then hybrid install SD->eMMC
  restore-emmc FILE   restore eMMC from .img/.img.gz backup

Env: BOARD PASS BACKUP_DIR SD_DEV EMMC_DEV SKIP_SD_BACKUP BS
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) YES=1; shift ;;
      *) break ;;
    esac
  done
  case "$cmd" in
    status) status_cmd ;;
    backup) cmd_backup ;;
    clone) cmd_clone ;;
    restore-emmc) restore_emmc "${1:-}" ;;
    -h|--help|help|"") usage ;;
    *) usage; die "unknown: $cmd" ;;
  esac
}

main "$@"
