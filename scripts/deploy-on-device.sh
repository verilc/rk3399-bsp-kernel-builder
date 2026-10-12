#!/bin/bash
# ============================================================================
# 在 TN3399_V3 (RK3399) 设备上安装新编译出来的 BSP 内核
#
# 用法（在设备上以 root 运行）：
#   bash deploy-on-device.sh /root/rk3399-bsp-6.1.xxx-rkbsp-tn3399.tar.zst
#
# 做的事：
#   1) 校验 sha256
#   2) 备份当前 /boot 引导文件到 /root/kernel-rollback/<时间戳>/
#   3) 安装模块到 /lib/modules/<新版本>   （旧内核模块保持不动，便于回滚）
#   4) 替换设备树 rk3399-tn3399-v3.dtb
#   5) 用新模块重新生成 /boot/uInitrd
#   6) 最后一步才替换 /boot/Image
#
# 回滚：bash rollback.sh
# ============================================================================
set -euo pipefail

TARBALL="${1:-}"
if [ -z "${TARBALL}" ]; then
  echo "用法: $0 <rk3399-bsp-*.tar.zst>"
  exit 1
fi
[ -f "${TARBALL}" ] || { echo "错误: 找不到文件 ${TARBALL}"; exit 1; }
if [ "$(id -u)" != "0" ]; then
  echo "错误: 请用 root 运行"; exit 1
fi

BOOT=/boot
DTBDIR="${BOOT}/dtb/rockchip"
DTBNAME=rk3399-tn3399-v3.dtb
BACKUP_ROOT=/root/kernel-rollback
WORK=/root/kernel-deploy
STAMP=$(date +%Y%m%d-%H%M%S)

echo "=============================================================="
echo " 当前内核: $(uname -r)"
echo " 新内核包: ${TARBALL}"
echo "=============================================================="

# ---------------------------------------------------------------- 1. 校验
if [ -f "${TARBALL}.sha256" ]; then
  echo "==> [1/7] 校验 sha256"
  ( cd "$(dirname "${TARBALL}")" && sha256sum -c "$(basename "${TARBALL}").sha256" )
else
  echo "==> [1/7] 未找到 .sha256 文件，跳过校验（建议手动核对）"
fi

# ---------------------------------------------------------------- 2. 解包
echo "==> [2/7] 解包"
rm -rf "${WORK}"; mkdir -p "${WORK}"
tar --zstd -xf "${TARBALL}" -C "${WORK}"

KREL=$(ls "${WORK}/modules/lib/modules/" 2>/dev/null | head -n1)
if [ -z "${KREL}" ]; then
  echo "错误: 压缩包里找不到 modules/lib/modules/<版本>"; exit 1
fi
NEW_SHORT="${KREL%%-*}"
echo "    包内内核版本: ${KREL}"
[ -f "${WORK}/kernel/Image" ] || { echo "错误: 包内缺少 kernel/Image"; exit 1; }
[ -f "${WORK}/kernel/${DTBNAME}" ] || { echo "错误: 包内缺少 ${DTBNAME}"; exit 1; }

# 防止把 6.18 的内核包误装到 6.1 目录
[ -n "${NEW_SHORT}" ] || { echo "错误: 无法解析内核版本"; exit 1; }

# ---------------------------------------------------------------- 3. 备份
echo "==> [3/7] 备份当前引导环境到 ${BACKUP_ROOT}/${STAMP}"
BK="${BACKUP_ROOT}/${STAMP}"
mkdir -p "${BK}"
for f in Image uInitrd armbianEnv.txt boot.scr boot.cmd; do
  [ -e "${BOOT}/${f}" ] && cp -a "${BOOT}/${f}" "${BK}/" || true
done
[ -e "${DTBDIR}/${DTBNAME}" ] && cp -a "${DTBDIR}/${DTBNAME}" "${BK}/${DTBNAME}.orig" || true
echo "${KREL}"                        > "${BK}/installed-version.txt"
uname -r                              > "${BK}/previous-running.txt"
ls -1 /lib/modules                    > "${BK}/modules-before.txt"
echo "    备份完成（旧内核模块 ${BACKUP_ROOT} 目录未动，仍在 /lib/modules 里）"

# ---------------------------------------------------------------- 4. 模块
echo "==> [4/7] 安装内核模块到 /lib/modules/${KREL}"
mkdir -p /lib/modules
if [ -d "/lib/modules/${KREL}" ]; then
  echo "    同名模块目录已存在，移动到 ${BK}/modules-replaced-${KREL}"
  mv "/lib/modules/${KREL}" "${BK}/modules-replaced-${KREL}"
fi
cp -a "${WORK}/modules/lib/modules/${KREL}" /lib/modules/
sync
if command -v depmod >/dev/null 2>&1; then
  depmod -a "${KREL}"
  echo "    depmod 完成"
fi

# ---------------------------------------------------------------- 5. DTB
echo "==> [5/7] 安装设备树 ${DTBNAME}"
mkdir -p "${DTBDIR}"
cp -a "${WORK}/kernel/${DTBNAME}" "${DTBDIR}/${DTBNAME}"

# ---------------------------------------------------------------- 6. initramfs
echo "==> [6/7] 生成 initramfs (mkinitramfs)"
if command -v mkinitramfs >/dev/null 2>&1; then
  mkinitramfs -o "${BOOT}/uInitrd.new" "${KREL}"
  ls -lh "${BOOT}/uInitrd.new"
  mv -f "${BOOT}/uInitrd.new" "${BOOT}/uInitrd"
else
  echo "    !! 找不到 mkinitramfs，请手动生成 uInitrd 后再重启"
  exit 1
fi

# ---------------------------------------------------------------- 7. Image
echo "==> [7/7] 安装内核镜像 /boot/Image"
cp -a "${WORK}/kernel/Image" "${BOOT}/Image"

echo
echo "=============================================================="
echo " 安装完成，请检查以下三项后重启："
echo "--------------------------------------------------------------"
echo " 1) boot 分区内容"
ls -lh "${BOOT}/Image" "${BOOT}/uInitrd" "${DTBDIR}/${DTBNAME}"
echo
echo " 2) armbianEnv.txt 是否指向正确设备树"
grep -nE "fdtfile|overlays|rootdev" "${BOOT}/armbianEnv.txt" || true
if grep -q "fdtfile=rockchip/${DTBNAME}" "${BOOT}/armbianEnv.txt" 2>/dev/null; then
  echo "    [OK] fdtfile 指向 rockchip/${DTBNAME}"
else
  echo "    [警告] 请确认 armbianEnv.txt 里 fdtfile=rockchip/${DTBNAME}"
fi
echo
echo " 3) 模块目录"
ls -d /lib/modules/* 2>/dev/null
echo
echo " 重启: reboot"
echo " 回滚: bash $(dirname "$0")/rollback.sh"
echo "=============================================================="
echo
echo "重启后按顺序验证："
echo "  uname -r                              # 应显示 ${KREL}"
echo "  ls -l /dev/mpp_service                # 出现即 MPP 驱动加载成功"
echo "  lsmod | grep -i mpp                   # rockchip_mpp / mpp_service_rkvdec..."
echo "  dmesg | grep -iE 'mpp|vepu|vpu'       # 看编码器探测日志"
echo "=============================================================="
