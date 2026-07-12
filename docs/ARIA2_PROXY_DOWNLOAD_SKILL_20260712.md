# aria2 + 代理下载固化（2026-07-12）

## 本机 Claude Skill

路径：`~/.claude/skills/aria2-proxy-download/`

| 文件 | 作用 |
|---|---|
| `SKILL.md` | 触发条件与工作流 |
| `scripts/aria2_proxy_dl.sh` | 通用多连接续传下载 |
| `scripts/dl_lpa_kernel_release.sh` | LPA 6.18 kernel release 三件套 |
| `references/runbook.md` | 故障排查 |

默认代理：`http://192.168.50.62:7890`  
`no_proxy`：`127.0.0.1,localhost,192.168.50.0/24`（板端直连）

## 仓库包装（无 skill 时也能用）

```bash
tools/aria2_proxy_dl.sh -o /tmp/dl URL
tools/dl_lpa_kernel_release.sh
# 自定义输出
OUT=/mnt/sdb3/LPA3399Pro/build_artifacts/mytag tools/dl_lpa_kernel_release.sh
```

## 已验证参数

```bash
aria2c -c -x 16 -s 16 -k 1M \
  --all-proxy=http://192.168.50.62:7890 \
  --connect-timeout=30 --timeout=120 \
  --max-tries=0 --retry-wait=2 \
  --auto-file-renaming=false --allow-overwrite=true \
  -d "$OUT/norm" -o FILE URL
```

## 成功样例

`build_artifacts/gha_bt_rtl_aria2_20260712_213251/norm/`

| 文件 | size |
|---|---:|
| Image | 49818112 |
| kos.tar.gz | 86410967 |
| dtbs.tar.gz | 1577990 |

下载后仍只做 SSH 增量部署，不生成新 `.img`。
