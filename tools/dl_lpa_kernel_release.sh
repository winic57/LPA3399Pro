#!/usr/bin/env bash
# Download LPA kernel 6.18 release assets via aria2 + proxy skill/wrapper.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="${HOME}/.claude/skills/aria2-proxy-download/scripts/dl_lpa_kernel_release.sh"
if [[ -x "$SKILL" ]]; then
  ROOT="$ROOT" OUT="${OUT:-}" PROXY="${PROXY:-http://192.168.50.62:7890}" exec "$SKILL" "$@"
fi
# Fallback: call local aria2_proxy_dl three times
PROXY="${PROXY:-http://192.168.50.62:7890}"
TAG="${TAG:-lpa_kernel_aria2_$(date +%Y%m%d_%H%M%S)}"
OUT="${OUT:-$ROOT/build_artifacts/$TAG}"
BASE="https://github.com/winic57/LPA3399Pro/releases/download/Neardi-LPA3399Pro-kernel-6.18"
mkdir -p "$OUT/norm"
for f in Image kos.tar.gz dtbs.tar.gz; do
  PROXY="$PROXY" "$ROOT/tools/aria2_proxy_dl.sh" -o "$OUT/norm" -n "$f" "$BASE/$f"
done
ls -la "$OUT/norm"
sha256sum "$OUT/norm"/*
echo "OUT=$OUT"
