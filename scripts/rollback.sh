#!/bin/bash
# ============================================================================
# 回滚到部署新内核之前的引导环境   [v2 - 适配符号链接]
#
# 用法（在设备上以 root 运行）：
#   bash rollback.sh                 # 交互确认后回滚到最近一次部署前
#   bash rollback.sh --yes           # 跳过确认（脚本/远程调用用）
#   bash rollback.sh --list          # 列出所有可回滚的时间点
#
# 原理：本机的 Image / uInitrd 是符号链接，部署时只是把链接指向了新版本，
#       旧内核文件（vmlinuz-<旧版本> / uInitrd-<旧版本>）从未被删除，
#       因此回滚 = 把符号链接指回去 + 还原设备树与 armbianEnv.txt。
#
# 注意：如果新内核根本起不来，SSH 进不来，这个脚本就用不上了，
#       那时只能靠 U 盘/TF 卡/串口救援或重刷。
# ============================================================================
set -euo pipefail

BACKUP_ROOT=/root/kernel-rollback
BOOT=/boot
DTBDIR=${BOOT}/dtb/rockchip
DTBNAME=rk3399-tn3399-v3.dtb
ASSUME_YES=false

for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=true ;;
    --list)   ls -1 "${BACKUP_ROOT}" 2>/dev/null || echo "  (无备份)"; exit 0 ;;
    *) echo "未知参数: $a"; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then echo "错误: 请用 root 运行"; exit 1; fi
if [ ! -d "${BACKUP_ROOT}" ]; then echo "错误: 找不到备份目录 ${BACKUP_ROOT}"; exit 1; fi

STAMP=$(ls -1 "${BACKUP_ROOT}" | sort | tail -n1)
[ -n "${STAMP}" ] || { echo "错误: 备份目录为空"; exit 1; }
BK="${BACKUP_ROOT}/${STAMP}"

echo "=============================================================="
echo " 即将回滚: ${BK}"
echo "  部署的版本:   $(cat "${BK}/installed-version.txt" 2>/dev/null || echo 未知)"
echo "  回滚目标版本: $(cat "${BK}/previous-running.txt" 2>/dev/null || echo 未知)"
echo "  Image  将指向: $(cat "${BK}/Image.target"   2>/dev/null || echo '(未记录)')"
echo "  uInitrd 将指向: $(cat "${BK}/uInitrd.target" 2>/dev/null || echo '(未记录)')"
echo "=============================================================="

if [ "${ASSUME_YES}" != "true" ]; then
  read -r -p "确认回滚? [y/N] " ans
  case "${ans}" in y|Y) ;; *) echo "已取消"; exit 0 ;; esac
fi

# 1) 符号链接
if [ -f "${BK}/Image.target" ]; then
  ln -sfn "$(cat "${BK}/Image.target")" "${BOOT}/Image"
  echo "  恢复链接 Image   -> $(readlink "${BOOT}/Image")"
fi
if [ -f "${BK}/uInitrd.target" ]; then
  ln -sfn "$(cat "${BK}/uInitrd.target")" "${BOOT}/uInitrd"
  echo "  恢复链接 uInitrd -> $(readlink "${BOOT}/uInitrd")"
fi

# 2) 普通文件（仅在新版本里被覆盖过的才需要还原）
for f in armbianEnv.txt; do
  if [ -f "${BK}/${f}" ]; then
    cp -a "${BK}/${f}" "${BOOT}/${f}"
    echo "  恢复 ${f}"
  fi
done

# 3) 设备树
if [ -f "${BK}/${DTBNAME}.orig" ]; then
  cp -a "${BK}/${DTBNAME}.orig" "${DTBDIR}/${DTBNAME}"
  echo "  恢复设备树 ${DTBNAME}"
fi

echo
echo "回滚完成，现在可以 reboot。"
echo "（新内核的 vmlinuz-*/uInitrd-* 文件与 /lib/modules/<新版本> 仍保留，不影响启动；"
echo "  确认稳定后可自行删除以省空间。）"
