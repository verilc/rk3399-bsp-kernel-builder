#!/bin/bash
# ============================================================================
# 回滚到部署新内核之前的引导环境
#
# 用法（在设备上以 root 运行）：
#   bash rollback.sh            # 回滚到最近一次部署前的状态
#   bash rollback.sh --list     # 列出所有可回滚的时间点
#
# 注意：如果新内核根本起不来，你连 SSH 都进不来，这个脚本就用不上了，
#       那时需要用 U 盘/TF卡救援或重刷。所以部署前务必确认救援手段。
# ============================================================================
set -euo pipefail

BACKUP_ROOT=/root/kernel-rollback
BOOT=/boot
DTBNAME=rk3399-tn3399-v3.dtb

if [ "$(id -u)" != "0" ]; then echo "错误: 请用 root 运行"; exit 1; fi

if [ "${1:-}" = "--list" ]; then
  echo "可回滚的时间点："
  ls -1 "${BACKUP_ROOT}" 2>/dev/null || echo "  (无备份)"
  exit 0
fi

if [ ! -d "${BACKUP_ROOT}" ]; then
  echo "错误: 找不到备份目录 ${BACKUP_ROOT}"; exit 1
fi

# 取最近一次备份（目录名按时间戳排序）
STAMP=$(ls -1 "${BACKUP_ROOT}" | sort | tail -n1)
[ -n "${STAMP}" ] || { echo "错误: 备份目录为空"; exit 1; }
BK="${BACKUP_ROOT}/${STAMP}"

echo "=============================================================="
echo " 正在回滚到: ${BK}"
echo "  安装版本:  $(cat "${BK}/installed-version.txt" 2>/dev/null || echo 未知)"
echo "  回滚目标:  $(cat "${BK}/previous-running.txt" 2>/dev/null || echo 未知)"
echo "=============================================================="
read -r -p "确认回滚? [y/N] " ans
case "${ans}" in y|Y) ;; *) echo "已取消"; exit 0 ;; esac

for f in Image uInitrd armbianEnv.txt boot.scr boot.cmd; do
  if [ -f "${BK}/${f}" ]; then
    cp -a "${BK}/${f}" "${BOOT}/${f}"
    echo "  恢复 ${f}"
  fi
done
if [ -f "${BK}/${DTBNAME}.orig" ]; then
  cp -a "${BK}/${DTBNAME}.orig" "${BOOT}/dtb/rockchip/${DTBNAME}"
  echo "  恢复设备树 ${DTBNAME}"
fi

echo
echo "回滚完成，现在可以 reboot。"
echo "（新内核的模块目录保留在 /lib/modules 里，不影响启动，可手动删除）"
