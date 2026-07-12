#!/usr/bin/env bash
# Install staged RKNN runtime onto live board via SSH.
# Expects host stage dir from build_artifacts/rknn_runtime_stage_*
set -euo pipefail
BOARD=${BOARD:-192.168.50.17}
PASS=${PASS:-1234}
STAGE=${STAGE:-/mnt/sdb3/LPA3399Pro/build_artifacts/rknn_runtime_stage_20260712}
REMOTE=${REMOTE:-/tmp/rknn_stage_install}
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$BOARD" "mkdir -p $REMOTE"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no \
  "$STAGE/python/Miniconda3-py37_4.9.2-Linux-aarch64.sh" \
  "$STAGE/wheels/"*.whl "$STAGE/wheels/"*.tar.gz \
  "$STAGE/lib/librknn_api.so" \
  "$STAGE/models/resnet_18.rknn" \
  "$STAGE/scripts/resnet18_zeros_test.py" \
  root@"$BOARD":"$REMOTE/" 2>/dev/null || true
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$BOARD" bash -s <<EOS
set -euo pipefail
REMOTE=$REMOTE
if [[ ! -x /opt/rknn_py39/bin/python ]]; then
  bash "\$REMOTE/Miniconda3-py37_4.9.2-Linux-aarch64.sh" -b -p /opt/rknn_py39
fi
mkdir -p /opt/py39_standalone
ln -sfn /opt/rknn_py39 /opt/py39_standalone/python
[[ -e /opt/rknn_py39/compiler_compat/ld ]] && mv /opt/rknn_py39/compiler_compat/ld /opt/rknn_py39/compiler_compat/ld.bak || true
install -m 0755 "\$REMOTE/librknn_api.so" /usr/lib/librknn_api.so
ldconfig || true
/opt/rknn_py39/bin/pip install --no-index --force-reinstall --no-deps \
  "\$REMOTE"/numpy-*.whl \
  "\$REMOTE"/ruamel.yaml.clib-*.whl \
  "\$REMOTE"/ruamel.yaml-*.whl \
  "\$REMOTE"/rknn_toolkit_lite-*.whl || true
if ! /opt/rknn_py39/bin/python -c 'import psutil' 2>/dev/null; then
  /opt/rknn_py39/bin/pip install --no-binary=:all: "\$REMOTE"/psutil-*.tar.gz
fi
mkdir -p /root/npu_deep_test
install -m 0644 "\$REMOTE/resnet18_zeros_test.py" /root/npu_deep_test/
install -m 0644 "\$REMOTE/resnet_18.rknn" /root/npu_deep_test/
/opt/rknn_py39/bin/python -c 'from rknnlite.api import RKNNLite; print("OK")'
echo INSTALL_RKNN_ENV_OK
EOS
