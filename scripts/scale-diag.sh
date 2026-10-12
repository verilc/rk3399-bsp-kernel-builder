#!/usr/bin/env bash
# =====================================================================
# 对照实验：为什么缩放这么贵？
# 对比「rkmpp 硬解出来的帧」 vs 「纯软件解码的帧」 做同一份 scale 工作
# =====================================================================
set -uo pipefail
export LC_ALL=C

RK=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
SYS=/usr/bin/ffmpeg
D=/tmp/camtest
SRC=$D/A1.h264
NFRAMES=438
TIMEFORMAT='%R %U %S'

run() {
  local label="$1"; shift
  { time "$@" >/dev/null 2>"$D/c.log" ; } 2>"$D/c.t"
  local real user sys
  read -r real user sys _ < "$D/c.t"
  real=${real:-0}; user=${user:-0}; sys=${sys:-0}
  local rc=$?
  printf '  %-40s 墙钟=%-8s CPU=%-8s 单核=%-8s 每帧=%s ms\n' \
    "$label" "$real" \
    "$(awk -v u=$user -v s=$sys 'BEGIN{printf "%.2f",u+s}')" \
    "$(awk -v u=$user -v s=$sys -v r=$real 'BEGIN{printf "%.1f",(u+s)/r*100}')" \
    "$(awk -v u=$user -v s=$sys -v n=$NFRAMES 'BEGIN{printf "%.1f",(u+s)*1000/n}')"
}

echo "===================================================================="
echo " 缩放成本对照（源 $SRC，438 帧 1080p，6 核）"
echo "===================================================================="
echo
echo "--- A. 纯软件 ffmpeg（系统 7.1.5，标准 NEON 优化）---"
run "A1 软解 → 丢弃" \
  "$SYS" -hide_banner -loglevel error -i "$SRC" -f null -
run "A2 软解 + scale 720p → 丢弃" \
  "$SYS" -hide_banner -loglevel error -i "$SRC" -vf scale=1280:720 -f null -
run "A3 软解 + scale 720p + x264" \
  "$SYS" -hide_banner -loglevel error -i "$SRC" -vf scale=1280:720 \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v 4000k -g 30 -f mp4 -y "$D/c.mp4"

echo
echo "--- B. rkmpp 版 ffmpeg（8.1.2）---"
run "B1 硬解 → 丢弃" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -f null -
run "B2 硬解 → hwdownload(yuv420p) → 丢弃" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf hwdownload,format=nv12,format=yuv420p -f null -
run "B3 硬解 + scale 720p → 丢弃" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf scale=1280:720 -f null -
run "B4 硬解 + hwdownload + scale + 丢弃" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf hwdownload,format=nv12,scale=1280:720 -f null -
run "B5 硬解 + 硬编 1080p（基线，不缩放）" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -c:v h264_rkmpp -rc_mode CBR -b:v 4000k -g 30 -bf 0 -f h264 -y "$D/c.h264"

echo
echo "--- C. 纯 scale 成本（无 I/O、无编码，同一帧反复缩放 20 次）---"
run "C1 软解 + scale 1080p->720p x20" \
  "$SYS" -hide_banner -loglevel error -i "$SRC" \
    -vf "scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080,scale=1280:720,scale=1920:1080" \
    -f null -

echo
echo "--- D. swscale 线程数影响 ---"
for t in 1 2 4; do
  run "D scale 720p  (filter_threads=$t)" \
    "$RK" -hide_banner -loglevel error -filter_threads $t -c:v h264_rkmpp -i "$SRC" \
      -vf scale=1280:720 -f null -
done

echo
echo "--- E. 输出格式对 scale 速度的影响（目标是给编码器喂 NV12）---"
run "E1 scale → nv12" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf scale=1280:720:flags=fast_bilinear,format=nv12 -f null -
run "E2 scale 指定转换算法 (spline 禁用/快速)" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf "scale=1280:720:flags=fast_bilinear+accurate_rnd" -f null -

echo
echo "--- F. 半分辨率缩放（只用 RGA/IEP 级别的简单降采样）---"
run "F1 scale 960x540" \
  "$RK" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" \
    -vf scale=960:540:flags=fast_bilinear -f null -

echo "===================================================================="
