#!/usr/bin/env bash
# =====================================================================
# 隔离实验：量化「缩放」这一步的真实 CPU 开销，以及摄像头裸速率
# 用固定文件源，排除摄像头变量，结果可复现
# =====================================================================
set -uo pipefail
export LC_ALL=C

FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
FFPROBE=/usr/local/ffmpeg-rkmpp/bin/ffprobe
D=/tmp/camtest
SRC=$D/A1.h264
TIMEFORMAT='%R %U %S'
NPROC=$(nproc)
ENC=(-c:v h264_rkmpp -rc_mode CBR -b:v 4000k -g 30 -bf 0 -profile:v main)

frames_of() {
  "$FFPROBE" -v error -f h264 -count_frames -select_streams v:0 \
    -show_entries stream=nb_read_frames -of csv=p=0 "$1" 2>/dev/null | tail -1
}

run() {
  local label="$1"; shift
  local of="$D/sc.h264"
  rm -f "$of"
  { time "$@" >"$of" 2>"$D/sc.log" ; } 2>"$D/sc.t"
  local real user sys n
  read -r real user sys _ < "$D/sc.t"
  real=${real:-0}; user=${user:-0}; sys=${sys:-0}
  n=$(frames_of "$of"); n=${n:-0}
  printf '  %-26s 帧=%-5s 墙钟=%-8s CPU=%-8s 单核=%-8s 每帧CPU=%s ms\n' \
    "$label" "$n" "$real" \
    "$(awk -v u=$user -v s=$sys 'BEGIN{printf "%.2f",u+s}')" \
    "$(awk -v u=$user -v s=$sys -v r=$real 'BEGIN{printf "%.1f",(u+s)/r*100}')" \
    "$(awk -v u=$user -v s=$sys -v n=$n 'BEGIN{if(n>0)printf "%.1f",(u+s)*1000/n; else print "-"}')"
  sleep 1
}

echo "===================================================================="
echo " 隔离实验：缩放 CPU 开销（源 = 固定 1080p H.264 文件，${NPROC} 核）"
echo "===================================================================="
echo " 源文件: $SRC  ($(ls -lh "$SRC" | awk '{print $5}'), $(frames_of "$SRC") 帧)"
echo

echo "--- 第 1 组：硬解 → 硬编，不同缩放实现 ---"
run "① 不缩放(1080p 原样)" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" "${ENC[@]}" -f h264 -y "$D/sc.h264"

run "② 缩放 scale 默认" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720 "${ENC[@]}" -f h264 -y "$D/sc.h264"

run "③ 缩放 fast_bilinear" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720:flags=fast_bilinear "${ENC[@]}" -f h264 -y "$D/sc.h264"

run "④ 缩放 fast_bilinear+nv12" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720:flags=fast_bilinear,format=nv12 "${ENC[@]}" -f h264 -y "$D/sc.h264"

run "⑤ 缩放 nv12+fast_bilinear" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf format=nv12,scale=1280:720:flags=fast_bilinear "${ENC[@]}" -f h264 -y "$D/sc.h264"

run "⑥ 缩放 neighbor(最近邻)" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720:flags=neighbor "${ENC[@]}" -f h264 -y "$D/sc.h264"

echo
echo "--- 第 2 组：只做缩放，不编码（看纯粹的 scale 代价）---"
run "⑦ 解码+缩放→ rawvideo 丢弃" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720:flags=fast_bilinear -f null -

run "⑧ 只解码 → 丢弃" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -f null -

echo
echo "--- 第 3 组：编码器分辨率是否影响开销 ---"
run "⑨ 硬解+硬编 720p(直接给 scale" \
  "$FF" -hide_banner -loglevel error -c:v h264_rkmpp -i "$SRC" -vf scale=1280:720:flags=fast_bilinear "${ENC[@]}" -f h264 -y "$D/sc.h264"

echo "===================================================================="
echo " 摄像头裸速率（绕过 ffmpeg，直接问驱动）"
echo "===================================================================="
echo " H264 模式，取 300 帧计时："
T0=$(date +%s.%N)
timeout 60 v4l2-ctl -d /dev/video1 --set-fmt-video=width=1920,height=1080,pixelformat=H264 \
  --stream-mmap --stream-count=300 --stream-to=/dev/null 2>&1 | tail -3
T1=$(date +%s.%N)
awk -v t0="$T0" -v t1="$T1" 'BEGIN{ d=t1-t0; printf "  → 300 帧耗时 %.2f s  ⇒ %.2f fps\n", d, 300/d }'

echo
echo " MJPG 模式，取 120 帧计时（带宽大，取少点）："
T0=$(date +%s.%N)
timeout 60 v4l2-ctl -d /dev/video1 --set-fmt-video=width=1920,height=1080,pixelformat=MJPG \
  --stream-mmap --stream-count=120 --stream-to=/dev/null 2>&1 | tail -3
T1=$(date +%s.%N)
awk -v t0="$T0" -v t1="$T1" 'BEGIN{ d=t1-t0; printf "  → 120 帧耗时 %.2f s  ⇒ %.2f fps\n", d, 120/d }'

echo
echo " 完成后要恢复默认格式："
v4l2-ctl -d /dev/video1 --set-fmt-video=width=1920,height=1080,pixelformat=MJPG >/dev/null 2>&1
echo " done"
