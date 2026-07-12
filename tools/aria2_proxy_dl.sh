#!/usr/bin/env bash
# Thin wrapper into the personal aria2-proxy-download skill (or in-repo fallback).
# Usage: tools/aria2_proxy_dl.sh -o OUTDIR URL [URL...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${HOME}/.claude/skills/aria2-proxy-download/scripts/aria2_proxy_dl.sh"
if [[ -x "$SKILL" ]]; then
  exec "$SKILL" "$@"
fi
# Fallback: inline minimal aria2 if skill missing
PROXY="${PROXY:-http://192.168.50.62:7890}"
OUTDIR=""
URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -n) OUTNAME="$2"; shift 2 ;;
    *) URLS+=("$1"); shift ;;
  esac
done
[[ -n "$OUTDIR" && ${#URLS[@]} -gt 0 ]] || { echo "usage: $0 -o OUTDIR URL..." >&2; exit 2; }
command -v aria2c >/dev/null || { echo "need aria2c" >&2; exit 3; }
mkdir -p "$OUTDIR"
for url in "${URLS[@]}"; do
  name="${OUTNAME:-$(basename "${url%%\?*}")}"
  aria2c -c -x 16 -s 16 -k 1M --all-proxy="$PROXY" \
    --connect-timeout=30 --timeout=120 --max-tries=0 --retry-wait=2 \
    --auto-file-renaming=false --allow-overwrite=true \
    -d "$OUTDIR" -o "$name" "$url"
  OUTNAME=""
done
