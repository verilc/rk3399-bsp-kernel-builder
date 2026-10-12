#!/usr/bin/env bash
# 本地辅助脚本：通过 plink 在 TN3399_V3 上执行命令 / 传输文件
# 用法:
#   bash scripts/dev.sh run "命令"
#   bash scripts/dev.sh put <本地文件> <远端路径>
#   bash scripts/dev.sh get <远端文件> <本地路径>
set -euo pipefail

# 关键：禁用 MSYS2/Git-Bash 的自动路径转换。
# 否则以 "/" 开头的远程命令（如 "/usr/local/... "）会被本地改写成
# "C:/Program Files/Git/usr/..."，导致板端报 "C:/Program: No such file or directory"。
export MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV=1

DEV_HOST="10.0.0.18"
DEV_USER="root"
DEV_PASS='fe4v52kn@'
DEV_KEY="SHA256:XUhRTNSJ99ix42MrRb7A2axyYOyNlSna6uI+fQ/e96Q"

PLINK_OPTS=(-batch -ssh -hostkey "$DEV_KEY" -pw "$DEV_PASS")

cmd="${1:-}"
shift || true

case "$cmd" in
  run)
    plink "${PLINK_OPTS[@]}" "${DEV_USER}@${DEV_HOST}" "$*"
    ;;
  put)
    pscp -batch -hostkey "$DEV_KEY" -pw "$DEV_PASS" "$1" "${DEV_USER}@${DEV_HOST}:$2"
    ;;
  get)
    pscp -batch -hostkey "$DEV_KEY" -pw "$DEV_PASS" "${DEV_USER}@${DEV_HOST}:$1" "$2"
    ;;
  *)
    echo "用法: $0 {run|put|get} ..." >&2
    exit 2
    ;;
esac
