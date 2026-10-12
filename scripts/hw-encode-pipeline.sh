#!/bin/bash
# ============================================================================
# RK3399 (TN3399_V3) 硬件编解码实时转码推流脚本
#
# 依赖（已随 BSP 内核部署好）：
#   /usr/local/ffmpeg-rkmpp/bin/ffmpeg   带 h264_rkmpp/hevc_rkmpp 编码器的 ffmpeg
#   /usr/local/lib/librockchip_mpp.so    Rockchip MPP 用户态库
#   /dev/mpp_service                     内核 MPP 驱动（BSP 6.1.172-rkbsp）
#
# 用法：
#   ./hw-encode-pipeline.sh info                       查看硬编/硬解/Mpp/摄像头状态
#   ./hw-encode-pipeline.sh cam                        列出摄像头及其支持的分辨率格式
#   ./hw-encode-pipeline.sh test [码率k]               1080p 合成源硬编到文件（自检）
#   ./hw-encode-pipeline.sh bench [宽 高]              跑四模式 CPU 对比基准
#   ./hw-encode-pipeline.sh file <输入> <输出.h264> [码率k]
#   ./hw-encode-pipeline.sh rtsp <输入> <rtsp地址>  [码率k]
#   ./hw-encode-pipeline.sh rtmp <输入> <rtmp地址>  [码率k]
#   ./hw-encode-pipeline.sh serve <输入> [名称] [码率k]   推到本机 MediaMTX
#
# 输入可以是：
#   /dev/video1                         USB 摄像头（UVC，自动取 MJPEG 1080p30）
#   rtsp://user:pass@ip:554/stream      网络摄像头 / NVR（自动硬解再硬编转码）
#   本地文件路径                        离线转码（自动按实时速率播放）
#
# 环境变量：
#   BR=4000           目标码率 kbps        GOP=60          关键帧间隔（帧）
#   RCMODE=CBR        VBR|CBR|CQP|AVBR     PROFILE=77      baseline=66 main=77 high=100
#   FPS=30            摄像头帧率              WITH_AUDIO=1    保留音频并转 AAC
#   RTSP_IN=tcp       RTSP 输入传输: tcp(默认，稳) 或 udp(更省 CPU)
#   SCALE=1280x720    缩放输出分辨率        FFMPEG=...      覆盖 ffmpeg 路径
#
# 示例：
#   ./hw-encode-pipeline.sh serve rtsp://admin:pass@192.168.1.64:554/Streaming/Channels/101 cam1 4000
#   ./hw-encode-pipeline.sh rtmp /dev/video1 rtmp://live-push.example.com/live/abc 6000
#   ./hw-encode-pipeline.sh file /dev/video1 /root/out.h264 4000
# ============================================================================
set -uo pipefail

FFMPEG=${FFMPEG:-/usr/local/ffmpeg-rkmpp/bin/ffmpeg}
FFPROBE=${FFPROBE:-/usr/local/ffmpeg-rkmpp/bin/ffprobe}
export LD_LIBRARY_PATH=/usr/local/lib:${LD_LIBRARY_PATH:-}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BR=${BR:-4000}
GOP=${GOP:-60}
FPS=${FPS:-30}
RCMODE=${RCMODE:-CBR}
PROFILE=${PROFILE:-77}
WITH_AUDIO=${WITH_AUDIO:-0}
RTSP_IN=${RTSP_IN:-tcp}
SCALE=${SCALE:-}
MTX_PORT=${MTX_PORT:-8554}

cmd="${1:-info}"

need() { [ -x "${FFMPEG}" ] || { echo "错误: 找不到 ${FFMPEG}"; exit 1; }; }
[ -e /dev/mpp_service ] || echo "警告: /dev/mpp_service 不存在，硬件编解码将不可用" >&2

# 把 profile 名称转成数值
case "$PROFILE" in
  baseline) PROFILE=66 ;; main) PROFILE=77 ;; high) PROFILE=100 ;;
esac

# --- 探测 RTSP 输入的视频编码格式，选出对应的 MPP 硬件解码器 ---------------
# 注意：不能用 `ffmpeg -decoders | grep -q`，因为在 set -o pipefail 下
#       grep 提前退出会让上游 ffmpeg 收到 SIGPIPE，整个管道被判为失败。
#       这里改成先把列表抓进变量，再用纯 bash 字符串匹配。
DEC_LIST=""
load_decoder_list() {
  [ -n "$DEC_LIST" ] && return
  DEC_LIST=$("$FFMPEG" -hide_banner -decoders 2>/dev/null || true)
}

pick_decoder() {
  local url="$1" codec cand
  codec=$(timeout 15 "$FFPROBE" -v error -rtsp_transport "$RTSP_IN" \
            -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 \
            "$url" 2>/dev/null | head -n 1 | tr -d '\r')
  codec="${codec##* }"                             # 防御性：只取最后一个词
  [ -z "$codec" ] && { echo ""; return; }          # 探测失败 -> 交给 ffmpeg 自动选

  case "$codec" in
    h264|hevc|mjpeg|mpeg4|mpeg2video|mpeg1video|vp8|vp9|av1|h263) ;;
    *) echo ""; return ;;                          # 未知编码 -> 自动
  esac

  cand="${codec}_rkmpp"
  load_decoder_list
  case "$DEC_LIST" in
    *" ${cand} "*) echo "$cand" ;;                 # 有硬解器
    *)             echo "" ;;                      # 无硬解器 -> 软解
  esac
}

# --- 根据输入类型组装「输入选项」 ------------------------------------------
# 结果写入全局数组 IN_OPTS 与变量 DECODER_DESC
build_input() {
  local in="$1"
  IN_OPTS=(); DECODER_DESC=""
  case "$in" in
    rtsp://*|rtmp://*|http://*|https://*)
      local dec; dec=$(pick_decoder "$in")
      if [ -n "$dec" ]; then
        IN_OPTS=(-c:v "$dec"); DECODER_DESC="硬件解码 ($dec)"
      else
        DECODER_DESC="软件解码"
      fi
      IN_OPTS+=(-rtsp_transport "$RTSP_IN" -fflags nobuffer -flags low_delay -i "$in")
      ;;
    /dev/video*)
      # UVC 摄像头：优先 MJPEG（省 USB 带宽，软解 JPEG 比软解 H.264 便宜）
      if v4l2-ctl -d "$in" --list-formats 2>/dev/null | grep -q MJPG; then
        IN_OPTS=(-f v4l2 -input_format mjpeg -video_size "${V4L2_SIZE:-1920x1080}"
                 -framerate "$FPS" -i "$in")
        DECODER_DESC="MJPEG 软解"
      else
        IN_OPTS=(-f v4l2 -video_size "${V4L2_SIZE:-1920x1080}" -framerate "$FPS" -i "$in")
        DECODER_DESC="原始帧"
      fi
      ;;
    *)
      IN_OPTS=(-re -i "$in"); DECODER_DESC="文件软解" ;;
  esac
}

# --- 组装「编码选项」 -------------------------------------------------------
build_encode() {
  ENC_OPTS=(-c:v h264_rkmpp -rc_mode "$RCMODE" -b:v "${BR}k"
            -maxrate "${BR}k" -bufsize "$((BR * 2))k"
            -g "$GOP" -bf 0 -profile:v "$PROFILE")
  [ -n "$SCALE" ] && ENC_OPTS+=(-vf "scale=${SCALE}")
  if [ "$WITH_AUDIO" = "1" ]; then
    ENC_OPTS+=(-c:a aac -b:a 128k -ar 44100)
  else
    ENC_OPTS+=(-an)
  fi
}

print_header() {
  echo ">>> 输入: $1"
  echo ">>> 解码: ${DECODER_DESC:-自动}"
  echo ">>> 编码: h264_rkmpp (RK3399 VEPU2)  ${RCMODE} ${BR}kbps  GOP ${GOP}  profile ${PROFILE}  ${SCALE:+缩放 ${SCALE} }(Ctrl-C 停止)"
  echo ">>> 输出: $2"$3
}

case "${cmd}" in
  # ------------------------------------------------------------------ info
  info)
    echo "=== 内核 ==="; uname -r
    echo; echo "=== /dev/mpp_service ==="
    ls -l /dev/mpp_service 2>/dev/null || echo "(缺失)"
    grep -iE 'mpp|vepu|vdpu|rkvdec|iep|rga' /proc/iomem 2>/dev/null | head -n 12
    echo; echo "=== 硬件编码器 ==="
    [ -x "$FFMPEG" ] && "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -E "rkmpp" || echo "(未找到)"
    echo; echo "=== 硬件解码器 ==="
    [ -x "$FFMPEG" ] && "$FFMPEG" -hide_banner -decoders 2>/dev/null | grep -E "rkmpp" || echo "(未找到)"
    echo; echo "=== 摄像头设备 ==="
    ls /dev/video* 2>/dev/null || echo "(无)"
    echo; echo "=== MediaMTX ==="
    systemctl is-active mediamtx 2>/dev/null || echo "(未运行)"
    ss -tln 2>/dev/null | grep -E ":${MTX_PORT}|:1935" || true
    echo; echo "=== 温度 / 负载 ==="
    for f in /sys/class/thermal/thermal_zone*/temp; do
      [ -r "$f" ] && awk -v z="$f" 'BEGIN{printf "%s: ", z}{printf "%.1f°C\n", $1/1000}' "$f"
    done 2>/dev/null | head -5
    cat /proc/loadavg
    ;;

  # ------------------------------------------------------------------- cam
  cam)
    if ! command -v v4l2-ctl >/dev/null; then echo "缺少 v4l2-ctl（apt install v4l-utils）"; exit 1; fi
    v4l2-ctl --list-devices 2>/dev/null || true
    for d in /dev/video*; do
      [ -e "$d" ] || continue
      echo "--- $d ---"
      v4l2-ctl -d "$d" --list-formats-ext 2>/dev/null | grep -E "^\s*\[|Size: Discrete" | head -n 20
    done
    ;;

  # ------------------------------------------------------------------ test
  test)
    need
    BR2=${2:-$BR}
    echo "=== 1080p30 合成源 -> h264_rkmpp -> 文件（10 秒）==="
    /usr/bin/time -v "$FFMPEG" -hide_banner -loglevel warning \
      -f lavfi -i testsrc2=size=1920x1080:rate=30 -t 10 \
      -c:v h264_rkmpp -rc_mode CBR -b:v "${BR2}k" -g 60 -bf 0 \
      -y /tmp/hw_test.h264 2>&1 | grep -E "Elapsed|User time|System time|Percent of CPU" || true
    ls -lh /tmp/hw_test.h264
    "$FFPROBE" -hide_banner -v error -show_entries stream=codec_name,profile,width,height \
      -of default=nw=1 /tmp/hw_test.h264
    ;;

  # ----------------------------------------------------------------- bench
  bench)
    if [ -x "${SCRIPT_DIR}/hw-encode-bench.sh" ]; then
      exec "${SCRIPT_DIR}/hw-encode-bench.sh"
    elif [ -x /root/hw-encode-bench.sh ]; then
      exec /root/hw-encode-bench.sh
    else
      echo "找不到 hw-encode-bench.sh"; exit 1
    fi
    ;;

  # ------------------------------------------------------- file / rtsp / rtmp
  file|rtsp|rtmp)
    need
    IN=${2:?缺少输入参数}
    OUT=${3:?缺少输出参数}
    [ $# -ge 4 ] && BR=$4
    build_input "$IN"
    build_encode
    case "${cmd}" in
      file) OUT_OPTS=(-f h264 "${OUT}") ;;
      rtmp) OUT_OPTS=(-f flv "${OUT}") ;;
      rtsp) OUT_OPTS=(-rtsp_transport tcp -f rtsp "${OUT}") ;;
    esac
    print_header "$IN" "$OUT" ""
    exec "$FFMPEG" -hide_banner -loglevel info -nostdin \
      "${IN_OPTS[@]}" "${ENC_OPTS[@]}" "${OUT_OPTS[@]}"
    ;;

  # ----------------------------------------------------------------- serve
  serve)
    need
    IN=${2:?缺少输入参数}
    NAME=${3:-cam1}
    [ $# -ge 4 ] && BR=$4
    OUT="rtsp://127.0.0.1:${MTX_PORT}/${NAME}"
    build_input "$IN"
    build_encode
    print_header "$IN" "$OUT" "   (拉流: ffplay rtsp://<板子IP>:${MTX_PORT}/${NAME})"
    exec "$FFMPEG" -hide_banner -loglevel info -nostdin \
      "${IN_OPTS[@]}" "${ENC_OPTS[@]}" -rtsp_transport tcp -f rtsp "${OUT}"
    ;;

  *)
    sed -n '2,45p' "$0"
    exit 1
    ;;
esac
