#!/usr/bin/env bash
# Poll GHA ophub 6.18 kernel build (CONFIG_BT_HCIUART_RTL), then SSH-deploy
# Image + modules to the running board. No full SD reflash.
set -euo pipefail

BOARD="${BOARD:-192.168.50.17}"
PASS="${PASS:-1234}"
PUBLIC_RUN="${PUBLIC_RUN:-29192980831}"
PRIVATE_RUN="${PRIVATE_RUN:-29192979474}"
PUBLIC_REPO="winic57/LPA3399Pro"
PRIVATE_REPO="winic57/LPA3399Pro-private"
POLL_SEC="${POLL_SEC:-120}"
MAX_WAIT_MIN="${MAX_WAIT_MIN:-150}"
WORKDIR="${WORKDIR:-/mnt/sdb3/LPA3399Pro/build_artifacts}"
LOG="${LOG:-/tmp/auto_deploy_bt_kernel_$(date +%Y%m%d_%H%M%S).log}"
TOKEN_URL="$(git -C /mnt/sdb3/LPA3399Pro remote get-url origin 2>/dev/null || true)"
TOKEN="$(printf '%s' "$TOKEN_URL" | sed -n 's#.*github_pat_\([^@]*\)@.*#github_pat_\1#p')"
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: cannot extract GitHub token from LPA origin remote" | tee -a "$LOG"
  exit 2
fi

exec > >(tee -a "$LOG") 2>&1
echo "=== auto deploy start $(date -Is) board=$BOARD log=$LOG ==="

api() {
  local url="$1"
  curl -sS --max-time 45 \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$url"
}

wait_run() {
  local repo="$1" rid="$2"
  local start_ts end_ts status conclusion
  start_ts=$(date +%s)
  end_ts=$((start_ts + MAX_WAIT_MIN * 60))
  while (( $(date +%s) < end_ts )); do
    local js
    js="$(api "https://api.github.com/repos/${repo}/actions/runs/${rid}")"
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))' <<<"$js")"
    conclusion="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("conclusion") or "")' <<<"$js")"
    echo "[$(date -Is)] ${repo} run ${rid}: status=${status} conclusion=${conclusion}"
    if [[ "$status" == "completed" ]]; then
      if [[ "$conclusion" == "success" ]]; then
        return 0
      fi
      echo "BUILD_FAILED ${repo} ${rid} conclusion=${conclusion}"
      return 1
    fi
    sleep "$POLL_SEC"
  done
  echo "TIMEOUT waiting for ${repo} ${rid}"
  return 1
}

download_artifacts() {
  local repo="$1" rid="$2" outdir="$3"
  mkdir -p "$outdir"
  local arts
  arts="$(api "https://api.github.com/repos/${repo}/actions/runs/${rid}/artifacts")"
  python3 - <<PY
import json,sys,urllib.request,os
arts=json.loads('''$arts''')
outdir=r'''$outdir'''
token=r'''$TOKEN'''
found=False
for a in arts.get('artifacts',[]):
    name=a.get('name','')
    print('artifact', name, 'expired', a.get('expired'), 'size', a.get('size_in_bytes'))
    if a.get('expired'):
        continue
    if 'ophub-kernel-6.18' in name or name.endswith('artifacts') or '6.18.33' in name:
        url=a['archive_download_url']
        dest=os.path.join(outdir, name + '.zip')
        print('download', url, '->', dest)
        req=urllib.request.Request(url, headers={
            'Authorization': f'Bearer {token}',
            'Accept': 'application/vnd.github+json',
        })
        with urllib.request.urlopen(req, timeout=600) as r, open(dest,'wb') as f:
            while True:
                chunk=r.read(1024*1024)
                if not chunk: break
                f.write(chunk)
        found=True
if not found:
    raise SystemExit('no matching artifacts')
print('ARTIFACTS_OK')
PY
  # unzip and normalize layout
  local z
  z="$(ls -1 "$outdir"/*.zip | head -1)"
  unzip -o "$z" -d "$outdir/unz"
  # find Image / kos / dtbs
  find "$outdir/unz" -type f | head -50
  mkdir -p "$outdir/norm"
  # common names
  if [[ -f "$outdir/unz/Image" ]]; then
    cp -a "$outdir/unz/Image" "$outdir/norm/Image"
  else
    find "$outdir/unz" -type f -name 'Image' -exec cp -a {} "$outdir/norm/Image" \;
  fi
  if [[ -f "$outdir/unz/kos.tar.gz" ]]; then
    cp -a "$outdir/unz/kos.tar.gz" "$outdir/norm/kos.tar.gz"
  else
    find "$outdir/unz" -type f -name 'kos.tar.gz' -exec cp -a {} "$outdir/norm/kos.tar.gz" \;
  fi
  if [[ -f "$outdir/unz/dtbs.tar.gz" ]]; then
    cp -a "$outdir/unz/dtbs.tar.gz" "$outdir/norm/dtbs.tar.gz"
  else
    find "$outdir/unz" -type f -name 'dtbs.tar.gz' -exec cp -a {} "$outdir/norm/dtbs.tar.gz" \; || true
  fi
  ls -la "$outdir/norm"
  [[ -s "$outdir/norm/Image" && -s "$outdir/norm/kos.tar.gz" ]] || {
    echo "missing Image/kos in artifacts"; return 1;
  }
}

# Prefer release assets if already updated
try_release() {
  local outdir="$1"
  mkdir -p "$outdir/norm"
  local base="https://github.com/winic57/LPA3399Pro/releases/download/Neardi-LPA3399Pro-kernel-6.18"
  local proxy="https://gitproxy.mrhjx.cn/https://github.com/winic57/LPA3399Pro/releases/download/Neardi-LPA3399Pro-kernel-6.18"
  for u in "$base" "$proxy"; do
    if curl -fL --connect-timeout 15 --max-time 30 -I "$u/Image" >/dev/null 2>&1; then
      echo "using release $u"
      curl -fL --retry 5 --retry-delay 3 -o "$outdir/norm/Image" "$u/Image"
      curl -fL --retry 5 --retry-delay 3 -o "$outdir/norm/kos.tar.gz" "$u/kos.tar.gz"
      curl -fL --retry 5 --retry-delay 3 -o "$outdir/norm/dtbs.tar.gz" "$u/dtbs.tar.gz" || true
      return 0
    fi
  done
  return 1
}

ssh_cmd() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 root@"$BOARD" "$@"
}
scp_cmd() {
  sshpass -p "$PASS" scp -o StrictHostKeyChecking=no "$@"
}

deploy_board() {
  local src="$1"
  local tag="bt_hciuart_rtl_$(date +%Y%m%d_%H%M%S)"
  local remote="/tmp/${tag}"
  echo "=== deploy $tag to $BOARD ==="
  ssh_cmd "mkdir -p '$remote'"
  scp_cmd "$src/Image" "$src/kos.tar.gz" root@"$BOARD":"$remote/"
  if [[ -s "$src/dtbs.tar.gz" ]]; then
    scp_cmd "$src/dtbs.tar.gz" root@"$BOARD":"$remote/" || true
  fi

  # remote deploy script
  ssh_cmd "cat > '$remote/deploy.sh' && chmod +x '$remote/deploy.sh'" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
REMOTE_DIR="$1"
TAG="$2"
BOOT=/boot
if ! mountpoint -q /boot; then
  mkdir -p /boot
  mount LABEL=BOOT /boot 2>/dev/null || mount /dev/mmcblk1p1 /boot
fi
echo "DEPLOY_START $(date -Is) tag=$TAG"
# backups
TS=$(date +%Y%m%d_%H%M%S)
cp -a /boot/Image "/boot/Image.pre_${TAG}_${TS}" 2>/dev/null || true
cp -a /boot/vmlinuz-6.18.33-rk35xx-ophub "/boot/vmlinuz-6.18.33-rk35xx-ophub.pre_${TAG}_${TS}" 2>/dev/null || true
[[ -f /boot/extlinux/extlinux.conf ]] && cp -a /boot/extlinux/extlinux.conf "/boot/extlinux/extlinux.conf.pre_${TAG}_${TS}"

install -m 0644 "$REMOTE_DIR/Image" /boot/Image
install -m 0644 "$REMOTE_DIR/Image" /boot/vmlinuz-6.18.33-rk35xx-ophub
# keep symlink if used
ln -sfn vmlinuz-6.18.33-rk35xx-ophub /boot/Image 2>/dev/null || true
# if Image is real file not symlink, leave installed file

# modules: install into versioned tree + uname symlink
MODVER=6.18.33-rk35xx-ophub
mkdir -p "/lib/modules/${MODVER}/extra-bt-rtl"
tmp=$(mktemp -d)
tar -xzf "$REMOTE_DIR/kos.tar.gz" -C "$tmp"
# overlay all kos into extra-bt-rtl and also replace matching names under extra/
find "$tmp" -type f -name '*.ko' | while read -r ko; do
  base=$(basename "$ko")
  install -m 0644 "$ko" "/lib/modules/${MODVER}/extra-bt-rtl/$base"
  # replace in extra/ if present
  if [[ -f "/lib/modules/${MODVER}/extra/$base" ]]; then
    install -m 0644 "$ko" "/lib/modules/${MODVER}/extra/$base"
  fi
done
ln -sfn "$MODVER" /lib/modules/6.18.33
# also if uname differs later
if [[ -d /lib/modules/$(uname -r) || true ]]; then
  ln -sfn "$MODVER" "/lib/modules/$(uname -r)" 2>/dev/null || true
fi
depmod -a 6.18.33 || depmod -a "$MODVER" || true

# ensure bluetooth DT still okay if current base dtb present
if command -v dtc >/dev/null && [[ -f /boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb ]]; then
  dtc -I dtb -O dts -o /tmp/cur.dts /boot/dtb/rockchip/rk3399pro-neardi-linux-lc110-base.dtb 2>/dev/null || true
  if grep -q 'serial@ff180000' /tmp/cur.dts 2>/dev/null; then
    # leave as-is if already okay
    true
  fi
fi

# keep stable cmdline markers
if [[ -f /boot/extlinux/extlinux.conf ]]; then
  grep -q 'maxcpus=4' /boot/extlinux/extlinux.conf || \
    sed -i 's/APPEND \(.*\)$/APPEND \1 maxcpus=4/' /boot/extlinux/extlinux.conf
fi

sync
echo "Image sha: $(sha256sum /boot/Image | awk '{print $1}')"
echo "DEPLOY_FILES_OK"
# reboot for new hci_uart
echo "REBOOTING"
sync
nohup bash -c 'sleep 2; reboot' >/dev/null 2>&1 &
EOS

  ssh_cmd "bash '$remote/deploy.sh' '$remote' '$tag'"
  echo "remote deploy issued; waiting for reboot..."
  sleep 25
  # wait SSH back
  for i in $(seq 1 60); do
    if ssh_cmd 'echo UP; uname -a; cat /proc/cmdline | tr " " "\n" | grep -E "maxcpus|PARTUUID" | head' 2>/dev/null; then
      break
    fi
    echo "wait ssh $i"
    sleep 5
  done

  # post verify BT
  ssh_cmd 'bash -s' <<'EOS'
set +e
# re-run wifi/bt bringup helpers if present
[[ -x /usr/local/sbin/lpa-wifi-bt-bringup.sh ]] && /usr/local/sbin/lpa-wifi-bt-bringup.sh || true
[[ -x /usr/local/bin/ec20-init.sh ]] && /usr/local/bin/ec20-init.sh || true
modprobe reset_gpio bluetooth btrtl hci_uart 2>/dev/null || true
sleep 2
echo '=== uname / config RTL ==='
uname -a
zcat /proc/config.gz 2>/dev/null | grep -E 'BT_HCIUART_RTL|BT_HCIUART=|BT_RTL' || true
# if config.gz not in new image, check module symbols
echo '=== hci_uart symbols RTL? ==='
modinfo hci_uart 2>/dev/null | head -20
ls /sys/module/hci_uart/holders 2>/dev/null
echo '=== bluetooth ==='
ls -la /sys/class/bluetooth 2>&1
hciconfig -a 2>&1 | head -40
dmesg | grep -iE 'Bluetooth|hci0|btrtl|RTL|8821' | tail -40
rfkill list 2>&1
lsusb | grep -i 2c7c || true
ip -br link
echo '=== DONE_VERIFY ==='
EOS
}

TAG_DIR="${WORKDIR}/gha_bt_rtl_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$TAG_DIR"

# Wait for either public or private success
ok_repo=""; ok_run=""
if wait_run "$PUBLIC_REPO" "$PUBLIC_RUN"; then
  ok_repo="$PUBLIC_REPO"; ok_run="$PUBLIC_RUN"
elif wait_run "$PRIVATE_REPO" "$PRIVATE_RUN"; then
  ok_repo="$PRIVATE_REPO"; ok_run="$PRIVATE_RUN"
else
  echo "both builds failed/timeout"; exit 3
fi
echo "BUILD_OK repo=$ok_repo run=$ok_run"

# Prefer release assets (workflow uploads to Neardi-LPA3399Pro-kernel-6.18)
if ! try_release "$TAG_DIR"; then
  echo "release not ready, downloading workflow artifacts..."
  download_artifacts "$ok_repo" "$ok_run" "$TAG_DIR"
fi

deploy_board "$TAG_DIR/norm"
echo "=== auto deploy finished $(date -Is) ==="
echo "LOG=$LOG"
echo "OUT=$TAG_DIR"
