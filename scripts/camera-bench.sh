#!/usr/bin/env bash
# =====================================================================
# UVC 摄像头 编解码性能基准（RK3399 VEPU2 硬件编码）
#
#   camera-bench.sh smoke   # 先做 3 秒连通性冒烟测试
#   camera-bench.sh bench   # 完整性能矩阵
#
# 环境变量： DEV=/dev/video1  W=1920 H=1080 FPS=30 DUR=15
# =====================================================================
set -uo pipefail
export LC_ALL=C

DEV="${DEV:-/dev/video1}"
W="${W:-1920}"
H="${H:-1080}"
FPS="${FPS:-30}"
DUR="${DUR:-15}"
SMOKE_DUR="${SMOKE_DUR:-3}"

FF="${FF:-/usr/local/ffmpeg-rkmpp/bin/ffmpeg}"
FFPROBE="${FFPROBE:-/usr/local/ffmpeg-rkmpp/bin/ffprobe}"
SYSFF="${SYSFF:-/usr/bin/ffmpeg}"
NPROC=$(nproc)

OUT=/tmp/camtest
mkdir -p "$OUT"
TIMEFORMAT='%R %U %S'

hr()  { printf '%s\n' "===================================================================="; }
sec() { echo; echo "--- $* ---"; }

# 只解析 [[:space:]] 分隔的三个数字
timing() { cat "$1" | tr -s ' \t\n' ' ' | sed 's/^ *//'; }

# ---------------------------------------------------------------- 环境
env_info() {
  hr; echo " 环境"; hr
  printf ' %-22s %s\n' "FFmpeg(rkmpp)" "$("$FF" -hide_banner -version 2>/dev/null | head -1)"
  printf ' %-22s %s\n' "FFmpeg(system)" "$(([ -x "$SYSFF" ] && "$SYSFF" -hide_banner -version 2>/dev/null | head -1) || echo '不存在')"
  printf ' %-22s %s\n' "CPU 核数" "$NPROC"
  printf ' %-22s %s\n' "内核" "$(uname -r)"
  printf ' %-22s %s\n' "MPP 设备" "$(ls -l /dev/mpp_service 2>/dev/null | awk '{print $1,$5,$6}')"
  printf ' %-22s %s\n' "摄像头节点" "$DEV  ($(cat /sys/class/video4linux/$(basename "$DEV")/name 2>/dev/null))"
  echo
  echo " 硬编码器:"
  "$FF" -hide_banner -encoders 2>/dev/null | grep -i rkmpp | sed 's/^/   /'
  echo " 硬解码器(常用):"
  "$FF" -hide_banner -decoders 2>/dev/null | grep -iE 'rkmpp' | grep -iE 'h264|mpeg4|mjpeg' | sed 's/^/   /'
}

# ------------------------------------------------- 单个用例的执行与统计
# run_case <标签> <输出文件> <ffmpeg 完整命令...>
run_case() {
  local label="$1"; shift
  local ofile="$1"; shift
  local tag; tag=$(echo "$label" | tr -cd 'A-Za-z0-9')
  local logf="$OUT/ff-$tag.log"
  local tf="$OUT/t-$tag.txt"
  rm -f "$ofile" "$logf" "$tf"

  # 确保设备没被别人占着
  if command -v fuser >/dev/null 2>&1; then
    fuser -k "$DEV" >/dev/null 2>&1 && sleep 1.5
  fi

  { time "$@" >"$ofile" 2>"$logf" ; } 2>"$tf"
  local rc=$?

  local real user sys
  read -r real user sys _ < <(timing "$tf")
  real=${real:-0}; user=${user:-0}; sys=${sys:-0}

  # ffmpeg 自己的进度行（带 \r，取最后一段）
  local frames ffps
  frames=$(grep -o 'frame=[ ]*[0-9]*' "$logf" 2>/dev/null | tail -1 | tr -dc '0-9')
  ffps=$(grep -o 'fps=[ ]*[0-9.]*' "$logf" 2>/dev/null | tail -1 | sed 's/fps=[ ]*//')
  frames=${frames:-0}; ffps=${ffps:-0}

  local bytes=0
  [ -f "$ofile" ] && bytes=$(stat -c %s "$ofile")

  local errs
  errs=$(grep -icE 'error|corrupt|Invalid|drop|non-existing' "$logf" 2>/dev/null)

  local cpu_pct
  cpu_pct=$(awk -v u="$user" -v s="$sys" -v r="$real" \
            'BEGIN{ if (r>0) printf "%.1f", (u+s)/r*100; else print 0 }')
  local cpu_per_core
  cpu_per_core=$(awk -v c="$cpu_pct" -v n="$NPROC" 'BEGIN{ printf "%.1f", c/n }')

  local measured_fps
  measured_fps=$(awk -v f="$frames" -v r="$real" 'BEGIN{ if (r>0) printf "%.1f", f/r; else print 0 }')

  # 结果打到 stderr（stdout 留给人看的汇总，这里直接打 stdout 也行）
  printf 'RESULT\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$rc" "$real" "$user" "$sys" "$cpu_pct" "$measured_fps" "$bytes" "$errs" "$ffps" \
    >&3

  echo "   $label"
  echo "     墙钟 ${real}s   CPU ${user}+${sys}=$(awk -v u="$user" -v s="$sys" 'BEGIN{printf "%.2f",u+s}')s"
  echo "     占用 ${cpu_pct}% 单核  (=${cpu_per_core}% 总机)   实测 ${measured_fps} fps  (ffmpeg 自报 ${ffps})"
  echo "     输出 $((bytes/1024)) KB   错误行 ${errs}"
  if [ "$rc" -ne 0 ] || [ "$frames" -eq 0 ]; then
    echo "     !! 失败 rc=$rc，日志尾部："
    tail -c 600 "$logf" 2>/dev/null | sed 's/^/        /'
  fi
  echo
  sleep 2
}

# ------------------------------------------------------------- smoke
smoke() {
  env_info
  hr; echo " 冒烟测试（各 ${SMOKE_DUR}s，确认取流能通）"; hr

  echo "[1] 摄像头 H264 直出"
  timeout 25 "$FF" -hide_banner -nostdin -loglevel warning \
    -f v4l2 -input_format h264 -video_size "${W}x${H}" -framerate "$FPS" \
    -i "$DEV" -t "$SMOKE_DUR" -c copy -f h264 -y "$OUT/smoke-h264.h264" 2>&1 | tail -8
  echo "    -> $([ -s "$OUT/smoke-h264.h264" ] && ls -lh "$OUT/smoke-h264.h264" | awk '{print $5}' || echo '空文件!')"

  echo "[2] 摄像头 MJPG 直出"
  timeout 25 "$FF" -hide_banner -nostdin -loglevel warning \
    -f v4l2 -input_format mjpeg -video_size "${W}x${H}" -framerate "$FPS" \
    -i "$DEV" -t "$SMOKE_DUR" -c copy -f mjpeg -y "$OUT/smoke-mjpg.mjpg" 2>&1 | tail -8
  echo "    -> $([ -s "$OUT/smoke-mjpg.mjpg" ] && ls -lh "$OUT/smoke-mjpg.mjpg" | awk '{print $5}' || echo '空文件!')"

  echo
  echo "若两个都是有效文件，说明 H264 与 MJPG 两条路都通。"
}

# ------------------------------------------------------------- bench
bench() {
  env_info
  hr; echo " 性能矩阵（每项 ${DUR}s）"; hr
  echo

  # 让 run_case 的结果同时写进一个 TSV
  local tsv="$OUT/results.tsv"
  : > "$tsv"
  exec 3>>"$tsv"

  local VIN_H264=(-f v4l2 -input_format h264 -video_size "${W}x${H}" -framerate "$FPS" -i "$DEV")
  local VIN_MJPG=(-f v4l2 -input_format mjpeg -video_size "${W}x${H}" -framerate "$FPS" -i "$DEV")
  local ENC_HW=(-c:v h264_rkmpp -rc_mode CBR -b:v 4000k -g 30 -bf 0 -profile:v main)

  echo "======== A. 摄像头 H264 直出（不做任何转码，基线） ========"
  run_case "A1 H264直通 -c copy" "$OUT/A1.h264" \
    "$FF" -hide_banner -nostdin -loglevel warning "${VIN_H264[@]}" \
    -t "$DUR" -c copy -f h264 -y "$OUT/A1.h264"

  echo "======== B. H264 源 → 硬解 + 硬编（全硬件转码） ========"
  run_case "B1 硬解+硬编 1080p" "$OUT/B1.h264" \
    "$FF" -hide_banner -nostdin -loglevel warning -c:v h264_rkmpp "${VIN_H264[@]}" \
    -t "$DUR" "${ENC_HW[@]}" -f h264 -y "$OUT/B1.h264"

  run_case "B2 硬解+硬编 720p(缩放)" "$OUT/B2.h264" \
    "$FF" -hide_banner -nostdin -loglevel warning -c:v h264_rkmpp "${VIN_H264[@]}" \
    -t "$DUR" -vf scale=1280:720 "${ENC_HW[@]}" -f h264 -y "$OUT/B2.h264"

  echo "======== C. MJPEG 源 → 硬解 + 硬编 ========"
  run_case "C1 MJPG硬解+硬编 1080p" "$OUT/C1.h264" \
    "$FF" -hide_banner -nostdin -loglevel warning -c:v mjpeg_rkmpp "${VIN_MJPG[@]}" \
    -t "$DUR" "${ENC_HW[@]}" -f h264 -y "$OUT/C1.h264"

  run_case "C2 MJPG硬解+硬编 720p" "$OUT/C2.h264" \
    "$FF" -hide_banner -nostdin -loglevel warning -c:v mjpeg_rkmpp "${VIN_MJPG[@]}" \
    -t "$DUR" -vf scale=1280:720 "${ENC_HW[@]}" -f h264 -y "$OUT/C2.h264"

  echo "======== D. 对照：软件编码 / 全软件 ========"
  if [ -x "$SYSFF" ]; then
    run_case "D1 硬解+软编 x264 1080p" "$OUT/D1.mp4" \
      "$FF" -hide_banner -nostdin -loglevel warning -c:v h264_rkmpp "${VIN_H264[@]}" \
      -t "$DUR" -c:v libx264 -preset ultrafast -tune zerolatency -b:v 4000k -g 30 \
      -f mp4 -y "$OUT/D1.mp4"

    run_case "D2 全软件 软解+软编 1080p" "$OUT/D2.mp4" \
      "$SYSFF" -hide_banner -nostdin -loglevel warning "${VIN_H264[@]}" \
      -t "$DUR" -c:v libx264 -preset ultrafast -tune zerolatency -b:v 4000k -g 30 \
      -f mp4 -y "$OUT/D2.mp4"
  else
    echo "   (系统 ffmpeg 不可用，跳过 D 组)"
  fi

  exec 3>&-
  echo
  echo "results.tsv:"
  cat "$tsv"
}

case "${1:-smoke}" in
  smoke) smoke ;;
  bench) bench ;;
  *) echo "用法: $0 {smoke|bench}"; exit 1 ;;
esac
