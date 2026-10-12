#!/usr/bin/env bash
# =============================================================================
# 板端端到端验证：RTSP 源 -> [硬编码/软编码] 转码 -> RTSP 输出 -> 读回校验
#
# 用途：量化「用 RK3399 VPU 硬编码替代 libx264」在真实推流链路里省下多少 CPU。
# 依赖：/usr/local/ffmpeg-rkmpp/bin/ffmpeg 与已运行的 MediaMTX（127.0.0.1:8554）
#
# 用法：
#   CODEC=h264_rkmpp DUR=30 ./hw-encode-e2e-test.sh
#   CODEC=libx264    DUR=30 ./hw-encode-e2e-test.sh
#   CODEC=h264_rkmpp SRC_W=1920 SRC_H=1080 SRC_FPS=30 DUR=30 ./hw-encode-e2e-test.sh
# =============================================================================
set -uo pipefail

FF="${FF:-/usr/local/ffmpeg-rkmpp/bin/ffmpeg}"
FFPROBE="${FFPROBE:-/usr/local/ffmpeg-rkmpp/bin/ffprobe}"
SYSFF="${SYSFF:-/usr/bin/ffmpeg}"      # 系统 ffmpeg，带 libx264，仅用于生成/发布参考源
MTX="${MTX:-rtsp://127.0.0.1:8554}"

CODEC="${CODEC:-h264_rkmpp}"
DUR="${DUR:-30}"                 # 读回采样时长（秒）
SRC_W="${SRC_W:-1280}"
SRC_H="${SRC_H:-720}"
SRC_FPS="${SRC_FPS:-30}"
BR="${BR:-2500k}"                # 目标码率
GOP="${GOP:-60}"
RCMODE="${RCMODE:-CBR}"
# profile 用数值最稳：baseline=66  main=77  high=100
case "${PROFILE:-main}" in
  baseline|66) PROF_NUM=66 ;;
  main|77)     PROF_NUM=77 ;;
  high|100)    PROF_NUM=100 ;;
  *)           PROF_NUM="${PROFILE:-77}" ;;
esac
SRC_SECS="${SRC_SECS:-60}"       # 参考源素材长度（秒），需 > DUR，避免循环导致时间戳回绕
SRC_FILE="${SRC_FILE:-/root/e2e-src-${SRC_W}x${SRC_H}.mp4}"   # 参考源文件（缓存复用）

CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- 读取某进程累计 CPU 时间（秒，utime+stime）---
proc_cpu() {
  local pid="$1" st
  [ -r "/proc/$pid/stat" ] || { echo -1; return; }
  st=$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null) || { echo -1; return; }
  [ -n "$st" ] || { echo -1; return; }
  awk -v t="$st" -v c="$CLK" 'BEGIN{printf "%.2f", t/c}'
}

# --- 读取某进程峰值 RSS（KB）---
proc_rss() {
  local pid="$1"
  [ -r "/proc/$pid/status" ] || { echo 0; return; }
  awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

PIDS=()
cleanup() {
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill -TERM "$p" 2>/dev/null
  done
  sleep 1
  for p in "${PIDS[@]:-}"; do
    [ -n "$p" ] && kill -KILL "$p" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 0. 前置检查
[ -x "$FF" ] || { echo "ERROR: 找不到 $FF"; exit 1; }
if [ "$CODEC" = "h264_rkmpp" ]; then
  [ -e /dev/mpp_service ] || { echo "ERROR: /dev/mpp_service 不存在，MPP 内核驱动未就绪"; exit 1; }
fi
ss -tln 2>/dev/null | grep -q ':8554' || { echo "ERROR: MediaMTX 未在 8554 监听"; exit 1; }

echo "=================================================================="
echo " 端到端推流验证"
echo " 源:        推送 ${SRC_W}x${SRC_H}@${SRC_FPS} 的 H.264 文件 (模拟摄像机, -c copy 零编码开销)"
echo " 转码编码器: ${CODEC}$( [ "$CODEC" = h264_rkmpp ] && echo '  <- RK3399 VEPU2 硬件编码' || echo '  <- CPU 软编码' )"
if [ "$CODEC" = "h264_rkmpp" ]; then
    echo "编码参数:  ${RCMODE} ${BR} / GOP ${GOP} / profile ${PROF_NUM} / -bf 0 / 低延迟(无B帧)"
fi
echo " 链路:      ${MTX}/src  ->  转码  ->  ${MTX}/out  ->  读回解码校验"
echo " 采样时长:  ${DUR}s"
echo "=================================================================="

# ------------------------------------------- 1. 准备参考源文件并模拟摄像机
if [ ! -s "$SRC_FILE" ]; then
  log "生成参考源文件 ${SRC_FILE} (仅首次, ${SRC_SECS}s 素材, 请稍候) ..."
  "$SYSFF" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${SRC_W}x${SRC_H}:rate=${SRC_FPS}" -t "$SRC_SECS" \
    -c:v libx264 -preset veryfast -g "$SRC_FPS" -pix_fmt yuv420p \
    -movflags +faststart "$SRC_FILE" \
    || { echo "ERROR: 参考源生成失败（$SYSFF 是否可用？）"; exit 1; }
fi
log "参考源: $(ls -lh "$SRC_FILE" | awk '{print $5}')"

SRC_LOG=/tmp/e2e-source.log
log "启动源发布 ${MTX}/src (-c copy, 实时速率) ..."
# -re 按实时速率推送；-c copy 不做编码，CPU 占用可忽略，等价于「从摄像机收流」
"$SYSFF" -hide_banner -loglevel warning -nostdin -re -i "$SRC_FILE" \
  -c copy -f rtsp -rtsp_transport tcp "${MTX}/src" >"$SRC_LOG" 2>&1 &
SRC_PID=$!; PIDS+=("$SRC_PID")
sleep 3

if ! kill -0 "$SRC_PID" 2>/dev/null; then
  echo "ERROR: 源发布失败："; tail -n 20 "$SRC_LOG"; exit 1
fi
SRC_CPU0=$(proc_cpu "$SRC_PID")
log "源已就绪 (pid=$SRC_PID)"

# -------------------------------------------------------------- 2. 启动转码
TRANS_LOG=/tmp/e2e-transcode.log
log "启动转码 ${MTX}/src -> ${MTX}/out ..."

if [ "$CODEC" = "h264_rkmpp" ]; then
  # 低延迟要点：-bf 0（禁用 B 帧）+ 较短 GOP；MPP 无 zerolatency 选项
  "$FF" -hide_banner -loglevel warning -nostdin \
    -rtsp_transport tcp -i "${MTX}/src" \
    -c:v h264_rkmpp -rc_mode "$RCMODE" -b:v "$BR" -maxrate "$BR" \
    -bufsize "$(awk -v b="${BR%k}" 'BEGIN{printf "%dk", b*2}')" \
    -g "$GOP" -bf 0 -profile:v "$PROF_NUM" \
    -f rtsp -rtsp_transport tcp "${MTX}/out" >"$TRANS_LOG" 2>&1 &
else
  "$SYSFF" -hide_banner -loglevel warning -nostdin \
    -rtsp_transport tcp -i "${MTX}/src" \
    -c:v libx264 -preset ultrafast -tune zerolatency -b:v "$BR" -g "$GOP" \
    -f rtsp -rtsp_transport tcp "${MTX}/out" >"$TRANS_LOG" 2>&1 &
fi
TR_PID=$!; PIDS+=("$TR_PID")
sleep 6

if ! kill -0 "$TR_PID" 2>/dev/null; then
  echo "ERROR: 转码进程启动失败："; tail -n 30 "$TRANS_LOG"; exit 1
fi
log "转码已就绪 (pid=$TR_PID)"

# ------------------------------------------------- 3. 读回并统计（采样窗口）
READ_LOG=/tmp/e2e-read.log
log "读回 ${MTX}/out，采样 ${DUR}s ..."

CPU0=$(proc_cpu "$TR_PID")
S0=$(date +%s.%N)

"$FF" -hide_banner -loglevel info -nostdin \
  -rtsp_transport tcp -i "${MTX}/out" -t "$DUR" -an -f null - >"$READ_LOG" 2>&1
READ_RC=$?

S1=$(date +%s.%N)
CPU1=$(proc_cpu "$TR_PID")
TR_RSS=$(proc_rss "$TR_PID")
SRC_CPU=$(awk -v a="$SRC_CPU0" -v b="$(proc_cpu "$SRC_PID")" 'BEGIN{printf "%.2f", b-a}')

WALL=$(awk -v a="$S0" -v b="$S1" 'BEGIN{printf "%.2f", b-a}')
DCPU=$(awk -v a="$CPU0" -v b="$CPU1" 'BEGIN{printf "%.2f", b-a}')

# -------------------------------------------------------- 4. 解析读回结果
FRAMES=$(grep -oE 'frame=\s*[0-9]+' "$READ_LOG" | tail -n1 | grep -oE '[0-9]+' || echo 0)
DEC_ERR=$(grep -ciE 'error|corrupt|invalid|concealing' "$READ_LOG" || true)
ACTUAL_FPS=$(awk -v f="${FRAMES:-0}" -v w="$WALL" 'BEGIN{ if(w>0) printf "%.1f", f/w; else print "0.0" }')
CPU_PCT=$(awk -v c="$DCPU" -v w="$WALL" 'BEGIN{ if(w>0) printf "%.0f", c/w*100; else print "0" }')

# 读回流的编码信息（确认确实是硬编码产出）
STREAM_INFO=$(timeout 15 "$FFPROBE" -v error -rtsp_transport tcp -select_streams v:0 \
  -show_entries stream=codec_name,profile,width,height,bit_rate,avg_frame_rate \
  -of default=nw=1 "${MTX}/out" 2>/dev/null | tr '\n' ' ' || true)

echo
echo "------------------------------------------------------------------"
echo " 结果（编码器 = ${CODEC}）"
echo "------------------------------------------------------------------"
printf " %-24s %s\n" "采样墙钟时间:"   "${WALL} s"
printf " %-24s %s\n" "读回帧数:"        "${FRAMES}"
printf " %-24s %s\n" "实际帧率:"        "${ACTUAL_FPS} fps  (源 ${SRC_FPS} fps)"
printf " %-24s %s\n" "转码进程 CPU 时间:" "${DCPU} s"
printf " %-24s %s\n" "转码进程 CPU 占用:" "${CPU_PCT} %   (相对单核)"
printf " %-24s %s\n" "源发布进程 CPU 时间:" "${SRC_CPU} s   (对照组，应接近 0)"
printf " %-24s %s\n" "转码进程峰值内存:"  "${TR_RSS} KB"
printf " %-24s %s\n" "读回解码错误数:"    "${DEC_ERR}"
printf " %-24s %s\n" "输出流信息:"        "${STREAM_INFO:-<未取到>}"
printf " %-24s %s\n" "读回 ffmpeg 返回码:" "${READ_RC}"
echo "------------------------------------------------------------------"

if [ "${DEC_ERR:-0}" -gt 0 ]; then
  echo " [警告] 读回日志出现疑似错误行，样例："
  grep -iE 'error|corrupt|invalid|concealing' "$READ_LOG" | head -n 5 | sed 's/^/   /'
fi
if [ "$TR_RSS" -gt 0 ] && [ "$DCPU" != "0.00" ] && [ "${FRAMES:-0}" -gt 0 ]; then
  PER_FRAME=$(awk -v c="$DCPU" -v f="$FRAMES" 'BEGIN{printf "%.2f", c/f*1000}')
  printf " %-24s %s\n" "每帧 CPU 成本:" "${PER_FRAME} ms-CPU/帧"
fi

echo
echo "转码进程日志尾部："
tail -n 8 "$TRANS_LOG" | sed 's/^/   /'
echo "=================================================================="
cleanup
trap - EXIT INT TERM
exit 0
