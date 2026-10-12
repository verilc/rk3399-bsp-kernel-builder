#!/bin/bash
# ============================================================================
# 在 TN3399_V3 (RK3399) 设备上安装新编译出来的 BSP 内核   [v2 - 适配符号链接]
#
# 用法（在设备上以 root 运行）：
#   bash deploy-on-device.sh /root/rk3399-bsp-6.1.xxx-rkbsp-tn3399.tar.zst
#
# 本机 /boot 的实际布局（Armbian 标准）：
#   Image   -> vmlinuz-<ver>        （符号链接）
#   uInitrd -> uInitrd-<ver>        （符号链接，内容是 mkimage 包装的 uImage）
#   因此本脚本【不覆盖旧内核文件】，而是新建 <新版本> 文件后重指符号链接：
#   回滚只需把链接指回去，旧内核文件始终完好。
#
# 做的事：
#   1) 校验 sha256
#   2) 解包
#   3) 备份引导环境（含符号链接指向记录）到 /root/kernel-rollback/<时间戳>/
#   4) 安装模块到 /lib/modules/<新版本> 并 depmod（旧模块目录不动）
#   5) 替换设备树 rk3399-tn3399-v3.dtb（旧文件备份为 .orig）
#   6) 用新模块生成 initramfs，并用 mkimage 打成 uImage（uInitrd-<新版本>）
#   7) 安装 vmlinuz-<新版本> / System.map / config，最后重指 Image 与 uInitrd 链接
#
# 本脚本【不会自动重启】，装完由你检查后再 reboot。
# 回滚：bash rollback.sh --yes
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
BK="${BACKUP_ROOT}/${STAMP}"

echo "=============================================================="
echo " 当前内核: $(uname -r)"
echo " 新内核包: ${TARBALL}"
echo " 备份目录: ${BK}"
echo "=============================================================="

# ---------------------------------------------------------------- 1. 校验
if [ -f "${TARBALL}.sha256" ]; then
  echo "==> [1/8] 校验 sha256"
  ( cd "$(dirname "${TARBALL}")" && sha256sum -c "$(basename "${TARBALL}").sha256" )
else
  echo "==> [1/8] 未找到 .sha256 文件，跳过校验"
fi

# ---------------------------------------------------------------- 2. 解包
echo "==> [2/8] 解包到 ${WORK}"
rm -rf "${WORK}"; mkdir -p "${WORK}"
tar --zstd -xf "${TARBALL}" -C "${WORK}"

KREL=$(ls "${WORK}/modules/lib/modules/" 2>/dev/null | head -n1)
[ -n "${KREL}" ] || { echo "错误: 压缩包里找不到 modules/lib/modules/<版本>"; exit 1; }
[ -f "${WORK}/kernel/Image" ]        || { echo "错误: 包内缺少 kernel/Image"; exit 1; }
[ -f "${WORK}/kernel/${DTBNAME}" ]   || { echo "错误: 包内缺少 ${DTBNAME}"; exit 1; }
echo "    包内内核版本: ${KREL}"
echo "    模块数量: $(find "${WORK}/modules" -name '*.ko' | wc -l)"

# ---------------------------------------------------------------- 3. 备份
echo "==> [3/8] 备份引导环境到 ${BK}"
mkdir -p "${BK}"
# 记录并保存符号链接（-a 保留链接本身），同时把“指向”写进文本，回滚时可精确复原
for f in Image uInitrd; do
  if [ -L "${BOOT}/${f}" ] || [ -e "${BOOT}/${f}" ]; then
    readlink "${BOOT}/${f}" > "${BK}/${f}.target" 2>/dev/null || true
    cp -a "${BOOT}/${f}" "${BK}/${f}.symlink"
  fi
done
for f in armbianEnv.txt boot.scr boot.cmd; do
  [ -e "${BOOT}/${f}" ] && cp -a "${BOOT}/${f}" "${BK}/" || true
done
[ -e "${DTBDIR}/${DTBNAME}" ] && cp -a "${DTBDIR}/${DTBNAME}" "${BK}/${DTBNAME}.orig" || true
echo "${KREL}"    > "${BK}/installed-version.txt"
uname -r          > "${BK}/previous-running.txt"
ls -1 /lib/modules > "${BK}/modules-before.txt"

# 生成一个备份目录内的独立复原脚本（即使 rollback.sh 丢失也能救）
cat > "${BK}/restore-here.sh" <<EOF
#!/bin/bash
# 恢复到 ${STAMP} 之前的引导状态
set -e
BOOT=/boot; DTBDIR=\$BOOT/dtb/rockchip
[ -f "${BK}/Image.target" ]   && ln -sfn "\$(cat "${BK}/Image.target")"   \$BOOT/Image
[ -f "${BK}/uInitrd.target" ] && ln -sfn "\$(cat "${BK}/uInitrd.target")" \$BOOT/uInitrd
[ -f "${BK}/armbianEnv.txt" ] && cp -a "${BK}/armbianEnv.txt" \$BOOT/
[ -f "${BK}/${DTBNAME}.orig" ] && cp -a "${BK}/${DTBNAME}.orig" \$DTBDIR/${DTBNAME}
echo "已恢复到 ${STAMP} 之前的状态，现在可以 reboot。"
EOF
chmod +x "${BK}/restore-here.sh"
echo "    备份完成: Image -> $(cat "${BK}/Image.target" 2>/dev/null || echo '(非链接)') ，uInitrd -> $(cat "${BK}/uInitrd.target" 2>/dev/null || echo '(非链接)')"

# ---------------------------------------------------------------- 4. 模块
echo "==> [4/8] 安装内核模块到 /lib/modules/${KREL}"
mkdir -p /lib/modules
if [ -d "/lib/modules/${KREL}" ]; then
  echo "    已存在同名模块目录，移动到 ${BK}/modules-replaced-${KREL}"
  mv "/lib/modules/${KREL}" "${BK}/modules-replaced-${KREL}"
fi
cp -a "${WORK}/modules/lib/modules/${KREL}" /lib/modules/
sync
depmod -a "${KREL}"
echo "    depmod 完成: $(ls /lib/modules/${KREL}/modules.dep >/dev/null 2>&1 && echo modules.dep 已生成 || echo '警告: modules.dep 缺失')"

# ---------------------------------------------------------------- 5. DTB
echo "==> [5/8] 安装设备树 ${DTBNAME}"
mkdir -p "${DTBDIR}"
cp -a "${WORK}/kernel/${DTBNAME}" "${DTBDIR}/${DTBNAME}"
dtc -I dtb -O dts -o /tmp/verify-new.dts "${DTBDIR}/${DTBNAME}" 2>/dev/null \
  && echo "    新 DTB 反编译校验通过（$(grep -c 'okay' /tmp/verify-new.dts) 个 okay）" \
  || echo "    !! 新 DTB 反编译失败，建议回滚"

# ---------------------------------------------------------------- 6. initramfs
echo "==> [6/8] 生成 initramfs 并打成 uImage"
NEW_INITRD_RAW="${BOOT}/initrd.img-${KREL}"
NEW_UINITRD="${BOOT}/uInitrd-${KREL}"
rm -f "${NEW_INITRD_RAW}" "${NEW_UINITRD}"
mkinitramfs -o "${NEW_INITRD_RAW}" "${KREL}"
ls -lh "${NEW_INITRD_RAW}"

# 按实际压缩算法选择 mkimage -C（Armbian 默认 COMPRESS=gzip，但这里做自动判断更稳）
COMP="none"
if   file "${NEW_INITRD_RAW}" | grep -qi gzip; then COMP="gzip"
elif file "${NEW_INITRD_RAW}" | grep -qi zstd; then COMP="zstd"
elif file "${NEW_INITRD_RAW}" | grep -qi lz4;  then COMP="lz4"
elif file "${NEW_INITRD_RAW}" | grep -qi xz;   then COMP="xz"
elif file "${NEW_INITRD_RAW}" | grep -qi bzip2;then COMP="bzip2"
fi
echo "    检测到压缩算法: ${COMP}"
mkimage -A arm64 -O linux -T ramdisk -C "${COMP}" -n uInitrd -d "${NEW_INITRD_RAW}" "${NEW_UINITRD}" >/dev/null
echo "    uImage 头部: $(head -c 4 "${NEW_UINITRD}" | od -An -tx1)"
echo "    initrd 内含模块数: $(lsinitramfs "${NEW_INITRD_RAW}" 2>/dev/null | grep -c '\.ko$' || echo 0)"
echo "    initrd 是否含新内核模块路径: $(lsinitramfs "${NEW_INITRD_RAW}" 2>/dev/null | grep -c "/${KREL}/" || echo 0) 条"

# ---------------------------------------------------------------- 7. 内核镜像
echo "==> [7/8] 安装内核镜像 vmlinuz-${KREL}"
cp -a "${WORK}/kernel/Image" "${BOOT}/vmlinuz-${KREL}"
[ -f "${WORK}/kernel/System.map-${KREL}" ] && cp -a "${WORK}/kernel/System.map-${KREL}" "${BOOT}/" || true
[ -f "${WORK}/kernel/config-${KREL}" ]     && cp -a "${WORK}/kernel/config-${KREL}"     "${BOOT}/" || true

# ---------------------------------------------------------------- 8. 切换符号链接
echo "==> [8/8] 切换符号链接（这一步之后才算真正生效）"
ln -sfn "vmlinuz-${KREL}" "${BOOT}/Image"
ln -sfn "uInitrd-${KREL}" "${BOOT}/uInitrd"

echo
echo "=============================================================="
echo " 安装完成。检查清单："
echo "--------------------------------------------------------------"
echo " 1) 链接指向"
ls -l "${BOOT}/Image" "${BOOT}/uInitrd"
echo
echo " 2) 关键文件"
ls -lh "${BOOT}/vmlinuz-${KREL}" "${BOOT}/uInitrd-${KREL}" "${DTBDIR}/${DTBNAME}"
echo
echo " 3) armbianEnv.txt 的 fdtfile"
grep -nE "fdtfile" "${BOOT}/armbianEnv.txt" || true
if grep -q "fdtfile=rockchip/${DTBNAME}" "${BOOT}/armbianEnv.txt" 2>/dev/null; then
  echo "    [OK] fdtfile 指向 rockchip/${DTBNAME}"
else
  echo "    [警告] fdtfile 与 ${DTBNAME} 不一致，请手工确认"
fi
echo
echo " 4) 模块目录"
ls -d /lib/modules/* 2>/dev/null
echo
echo " 5) 旧内核文件仍在（回滚靠它）"
ls -l "${BOOT}"/vmlinuz-* "${BOOT}"/uInitrd-* 2>/dev/null
echo "=============================================================="
echo " 重启: reboot"
echo " 回滚: bash $(cd "$(dirname "$0")" && pwd)/rollback.sh --yes"
echo "       （或 bash ${BK}/restore-here.sh）"
echo "=============================================================="
echo
echo "重启后按顺序验证："
echo "  uname -r                              # 应为 ${KREL}"
echo "  ls -l /dev/mpp_service                # 出现即 MPP 驱动加载成功"
echo "  dmesg | grep -iE 'mpp|vepu|vpu'       # 看编码器探测日志"
echo "  cat /proc/mpp_service/supports        # 支持能力列表"
echo "=============================================================="
