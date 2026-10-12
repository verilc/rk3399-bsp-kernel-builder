#!/usr/bin/env bash
# =====================================================================
# UVC 摄像头探测 —— 列设备、列格式/分辨率/帧率、测实际取流吞吐
#   用法:  probe-camera.sh            # 全部探测
#          probe-camera.sh <dev>      # 只探测指定节点
# =====================================================================
set -uo pipefail

DEV="${1:-}"

hr() { printf '%s\n' "--------------------------------------------------------------------"; }
sec() { echo; echo "### $*"; }

sec "1. USB 设备树（确认摄像头被枚举）"
lsusb 2>/dev/null || echo "  (无 lsusb)"
echo
echo "  --- USB 拓扑 ---"
lsusb -t 2>/dev/null || echo "  (无 lsusb -t)"

sec "2. V4L2 视频节点"
for d in /sys/class/video4linux/*; do
  [ -e "$d" ] || continue
  node="/dev/$(basename "$d")"
  name=$(cat "$d/name" 2>/dev/null)
  idx=$(cat "$d/index" 2>/dev/null)
  printf '  %-16s index=%-3s %s\n' "$node" "$idx" "$name"
done

sec "3. 判断哪些节点是「取流用的」（有 Video Capture 能力）"
which v4l2-ctl >/dev/null 2>&1 || echo "  !! v4l2-ctl 未安装（apt install v4l-utils）"
if which v4l2-ctl >/dev/null 2>&1; then
  echo "  --- 全部设备列表 ---"
  v4l2-ctl --list-devices 2>&1
fi

# 自动挑出候选取流节点
CANDIDATES=()
if [ -n "$DEV" ]; then
  CANDIDATES=("$DEV")
else
  for d in /sys/class/video4linux/*; do
    [ -e "$d" ] || continue
    node="/dev/$(basename "$d")"
    # 只保留能 capture 的
    if v4l2-ctl -d "$node" --list-formats >/dev/null 2>&1; then
      CANDIDATES+=("$node")
    fi
  done
fi

if [ ${#CANDIDATES[@]} -eq 0 ]; then
  echo
  echo "!! 没找到可用的取流节点。摄像头可能没插好，或需要重新插拔。"
  exit 1
fi

echo
echo "  候选取流节点: ${CANDIDATES[*]}"

sec "4. 各节点支持的格式 / 分辨率 / 帧率（这是关键的协商能力表）"
for node in "${CANDIDATES[@]}"; do
  hr
  echo ">>> $node  ($(cat /sys/class/video4linux/$(basename "$node")/name 2>/dev/null))"
  hr
  v4l2-ctl -d "$node" --list-formats-ext 2>&1 | sed 's/^/  /'
done

sec "5. 当前已经协商的格式（若已被占用）"
for node in "${CANDIDATES[@]}"; do
  echo "  --- $node ---"
  v4l2-ctl -d "$node" --get-fmt-video 2>&1 | sed 's/^/    /'
  v4l2-ctl -d "$node" --get-parm 2>&1 | sed 's/^/    /'
done

sec "6. USB 带宽/供电相关的内核日志（找掉线、重置、带宽不足）"
dmesg 2>/dev/null | grep -iE 'uvcvideo|usb .*reset|usb .*disconnect|usb .*error|over.?current|not enough bandwidth|xhci.*(hang|died)|device descriptor' | tail -n 40 | sed 's/^/  /'

sec "7. 摄像头所在 USB 控制器的速度与链路"
for d in /sys/bus/usb/devices/*; do
  [ -f "$d/idVendor" ] || continue
  prod=$(cat "$d/product" 2>/dev/null)
  case "$prod" in
    *UVC*|*Camera*|*camera*|*Imx*|*IMX*|*USB*Video*|*webcam*|*Webcam*)
      spd=$(cat "$d/speed" 2>/dev/null)
      maxp=$(cat "$d/bMaxPower" 2>/dev/null)
      mfr=$(cat "$d/manufacturer" 2>/dev/null)
      echo "  $(basename "$d"): $prod"
      echo "    厂商=$mfr  速度=${spd}Mbps  最大功耗=${maxp}"
      # 向上找控制器
      p="$d"
      while [ "$(basename "$p")" != "usb1" ] && [ "$(basename "$p")" != "usb2" ] && [ "$(basename "$p")" != "usb3" ] && [ "$(basename "$p")" != "usb4" ] && [ "$(basename "$p")" != "usb5" ] && [ "$(basename "$p")" != "devices" ] && [ "$p" != "/sys/bus/usb/devices" ]; do
        p=$(dirname "$p")
      done
      echo "    挂在: $(basename "$p")"
      cat "/sys/bus/usb/devices/$(basename "$p")/product" 2>/dev/null | sed 's/^/    控制器: /'
      ;;
  esac
done

sec "8. USB 主机控制器驱动与运行模式"
for c in /sys/bus/platform/drivers/*hci*/fe*.usb; do
  [ -e "$c" ] || continue
  echo "  $(basename "$c")  ->  $(readlink -f "$c" 2>/dev/null)"
done
echo
echo "  --- xhci/ehci/ohci/dwc3 驱动绑定 ---"
ls -l /sys/bus/platform/drivers/ 2>/dev/null | grep -iE 'xhci|ehci|ohci|dwc3' | sed 's/^/  /'

sec "9. 当前 USB 带宽占用（等时端点预算）"
for d in /sys/bus/usb/devices/usb*; do
  [ -e "$d" ] || continue
  echo "  $(basename "$d"): $(cat "$d/product" 2>/dev/null) speed=$(cat "$d/speed" 2>/dev/null)Mbps"
done

echo
echo "===================== 探测结束 ====================="
