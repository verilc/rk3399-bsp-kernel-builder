#!/usr/bin/env bash
# =============================================================================
# RK3399 推流链路 CPU 开销对比基准
#
# 链路：模拟摄像机 -> MediaMTX(/src) -> [解码 + 重编码] -> MediaMTX(/out) -> 录制校验
#
# 对比 4 种转码方式（每种方式测量「转码进程」自身的 CPU 时间）：
#   1. copy        纯转发    : 不解码不编码，链路开销下限（对照）
#   2. mpp+mpp     全硬件    : MPP 硬解 + MPP 硬编   <- 目标方案
#   3. sw+mpp      软解硬编  : CPU 软解 + MPP 硬编
#   4. sw+x264     纯软编码  : CPU 软解 + libx264 软编（改造前的做法）
#
# 用法：
#   ./hw-encode-bench.sh                     # 720p30
#   SRC_W=1920 SRC_H=1080 ./hw-encode-bench.sh
#   DUR=20 BR=2500k ./hw-encode-bench.sh
# =============================================================================
set -uo pipefail

FF="${FF:-/usr/local/ffmpeg-rkmpp/bin/ffmpeg}"
FFPROBE="${FFPROBE:-/usr/local/ffmpeg-rkmpp/bin/ffprobe}"
SYSFF="${SYSFF:-/usr/bin/ffmpeg}"
MTX="${MTX:-rtsp://127.0.0.1:8554}"

DUR="${DUR:-20}"                  # 每种方式的采样时长（秒）
SRC_W="${SRC_W:-1280}"
SRC_H="${SRC_H:-720}"
SRC_FPS="${SRC_FPS:-30}"
SRC_SECS="${SRC_SECS:-40}"
BR="${BR:-2500k}"
GOP="${GOP:-60}"
SRC_FILE="${SRC_FILE:-/root/bench-src-${SRC_W}x${SRC_H}.mp4}"
REC_FILE="/tmp/bench-out.ts"

CLK=$(getconf CLK_TCK 2>/dev/null || echo 100)
RESULT_TSV=/tmp/bench-result.tsv
: > "$RESULT_TSV"

log() { echo "[$(date +%H:%M:%S)] $*"; }

proc_cpu() {   # 累计 CPU 秒数
  local pid="$1"
  [ -r "/proc/$pid/stat" ] || { echo -1; return; }
  awk -v c="$CLK" '{printf "%.2f", ($14+$15)/c}' "/proc/$pid/stat" 2>/dev/null || echo -1
}
proc_rss() {   # 峰值 RSS (KB)
  local pid="$1"
  [ -r "/proc/$pid/status" ] && awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

PIDS=()
kill_all() {
  local p
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; done
  sleep 1
  for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  PIDS=()
  sleep 1
}
trap 'kill_all' EXIT INT TERM

# ------------------------------------------------------------------ 前置检查
[ -x "$FF" ] || { echo "ERROR: 缺少 $FF"; exit 1; }
[ -e /dev/mpp_service ] || { echo "ERROR: /dev/mpp_service 不存在"; exit 1; }
ss -tln 2>/dev/null | grep -q ':8554' || { echo "ERROR: MediaMTX 未监听 8554"; exit 1; }

# ------------------------------------------------------------ 准备参考源素材
if [ ! -s "$SRC_FILE" ]; then
  log "生成参考源 ${SRC_FILE} (${SRC_W}x${SRC_H}, ${SRC_SECS}s, 仅首次) ..."
  "$SYSFF" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=${SRC_W}x${SRC_H}:rate=${SRC_FPS}" -t "$SRC_SECS" \
    -c:v libx264 -preset veryfast -g "$SRC_FPS" -pix_fmt yuv420p \
    -movflags +faststart "$SRC_FILE" || { echo "ERROR: 素材生成失败"; exit 1; }
fi

echo "======================================================================"
echo " RK3399 推流链路 CPU 开销基准"
echo " 规格: ${SRC_W}x${SRC_H}@${SRC_FPS}   目标码率: ${BR}   GOP: ${GOP}"
echo " 每种方式采样: ${DUR}s"
echo " 转码内核: $(uname -r)   CPU: $(nproc) 核"
echo "======================================================================"

# ============================================================ 单种方式测量
# 参数: <显示名> <输入附加选项串> <编码器: mpp|copy|x264>
run_mode() {
  local label="$1" in_opts="$2" enc="$3"
  local tr_log=/tmp/bench-${label//[^a-zA-Z0-9]/_}.log

  kill_all
  rm -f "$REC_FILE"

  # --- 源（模拟摄像机，-c copy 零编码开销）---
  "$SYSFF" -hide_banner -loglevel error -nostdin -re -i "$SRC_FILE" \
    -c copy -f rtsp -rtsp_transport tcp "${MTX}/src" >/tmp/bench-src.log 2>&1 &
  local src_pid=$!; PIDS+=("$src_pid")
  sleep 3
  kill -0 "$src_pid" 2>/dev/null || { echo "  [跳过] 源发布失败"; tail -3 /tmp/bench-src.log; return 1; }

  # --- 转码 ---
  local bin="$FF" out_opts=()
  case "$enc" in
    mpp)
      out_opts=(-c:v h264_rkmpp -rc_mode CBR -b:v "$BR" -maxrate "$BR"
                -bufsize "$(awk -v b="${BR%k}" 'BEGIN{printf "%dk", b*2}')"
                -g "$GOP" -bf 0 -profile:v 77) ;;
    copy) out_opts=(-c:v copy) ;;
    x264) bin="$SYSFF"
          out_opts=(-c:v libx264 -preset ultrafast -tune zerolatency -b:v "$BR" -g "$GOP" -bf 0) ;;
  esac

  # shellcheck disable=SC2086
  "$bin" -hide_banner -loglevel warning -nostdin \
    $in_opts -rtsp_transport tcp -i "${MTX}/src" \
    "${out_opts[@]}" -f rtsp -rtsp_transport tcp "${MTX}/out" >"$tr_log" 2>&1 &
  local tr_pid=$!; PIDS+=("$tr_pid")
  sleep 5

  if ! kill -0 "$tr_pid" 2>/dev/null; then
    echo "  [跳过] 转码进程启动失败：$(tail -n 2 "$tr_log" | tr '\n' ' ')"
    return 1
  fi

  # --- 采样窗口：仅做 RTP 转发录制（不软解，避免干扰被测进程）---
  local cpu0 s0 s1 cpu1
  cpu0=$(proc_cpu "$tr_pid")
  s0=$(date +%s.%N)
  "$FF" -hide_banner -loglevel error -nostdin -rtsp_transport tcp -i "${MTX}/out" \
    -t "$DUR" -c copy -f mpegts -y "$REC_FILE" >/dev/null 2>&1
  local rec_rc=$?
  s1=$(date +%s.%N)
  cpu1=$(proc_cpu "$tr_pid")

  local wall dcpu rss fps
  wall=$(awk -v a="$s0" -v b="$s1" 'BEGIN{printf "%.2f", b-a}')
  dcpu=$(awk -v a="$cpu0" -v b="$cpu1" 'BEGIN{printf "%.2f", b-a}')
  rss=$(proc_rss "$tr_pid")

  # --- 离线统计帧数与解码错误（此时转码进程已不再是瓶颈）---
  local frames=0
  if [ -s "$REC_FILE" ]; then
    frames=$(timeout 120 "$FFPROBE" -v error -count_frames -select_streams v:0 \
      -show_entries stream=nb_read_frames -of csv=p=0 "$REC_FILE" 2>/dev/null | head -n1)
    frames=${frames:-0}
  fi
  local errs=0
  [ -s "$REC_FILE" ] && errs=$(timeout 120 "$FF" -v error -i "$REC_FILE" -f null - 2>&1 | grep -c . || true)

  fps=$(awk -v f="${frames:-0}" -v w="$wall" 'BEGIN{ if(w>0) printf "%.1f", f/w; else print "0.0" }')
  local pct per_frame
  pct=$(awk -v c="$dcpu" -v w="$wall" 'BEGIN{ if(w>0) printf "%.0f", c/w*100; else print "0" }')
  per_frame=$(awk -v c="$dcpu" -v f="${frames:-0}" 'BEGIN{ if(f>0) printf "%.2f", c/f*1000; else print "n/a" }')

  printf " %-10s | %6.1f fps | %8.2f s | %5s %% | %10s ms/帧 | %6s KB | %4s 错\n" \
    "$label" "$fps" "$dcpu" "$pct" "$per_frame" "$rss" "$errs"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$label" "$SRC_W" "$SRC_H" "$fps" "$dcpu" "$pct" "$per_frame" "$errs" >> "$RESULT_TSV"

  [ "$rec_rc" -ne 0 ] && echo "        (注意: 录制进程返回码 $rec_rc)"
  return 0
}

# ================================================================== 主流程
echo
printf " %-10s | %9s | %10s | %6s | %14s | %9s | %s\n" \
  "方式" "实际帧率" "CPU时间" "单核占用" "每帧CPU" "峰值内存" "解码错误"
echo "------------+-----------+------------+--------+----------------+-----------+---------"
run_mode "copy"    ""                     copy
run_mode "mpp+mpp" "-c:v h264_rkmpp"      mpp
run_mode "sw+mpp"  ""                     mpp
run_mode "sw+x264" ""                     x264
echo

# ------------------------------------------------------------ 汇总与结论
if [ -s "$RESULT_TSV" ]; then
  echo "======================================================================"
  echo " 汇总"
  echo "======================================================================"
  awk -F'\t' '
    { cpu[$1]=$5+0; per[$1]=$7; fps[$1]=$4; rss[$1]=$6 }
    END {
      base=cpu["copy"]; if (base=="") base=0
      printf " %-10s %-14s %-12s %s\n", "方式", "CPU时间(s)", "相对copy", "每帧CPU"
      split("copy mpp+mpp sw+mpp sw+x264", ord, " ")
      for (i=1;i<=4;i++) {
        k=ord[i]; if (!(k in cpu)) continue
        if (base>0) printf " %-10s %-14.2f %-12s %s\n", k, cpu[k], sprintf("x%.1f", cpu[k]/base), per[k]
        else        printf " %-10s %-14.2f %-12s %s\n", k, cpu[k], "-", per[k]
      }
      if (("sw+x264" in cpu) && ("mpp+mpp" in cpu) && cpu["mpp+mpp"]>0)
        printf "\n >> 纯软编码 vs 全硬件: CPU 降到 1/%.1f (省 %.0f%%)\n", \
               cpu["sw+x264"]/cpu["mpp+mpp"], (1-cpu["mpp+mpp"]/cpu["sw+x264"])*100
      if (("sw+x264" in cpu) && ("sw+mpp" in cpu) && cpu["sw+mpp"]>0)
        printf " >> 纯软编码 vs 软解硬编: CPU 降到 1/%.1f (省 %.0f%%)\n", \
               cpu["sw+x264"]/cpu["sw+mpp"], (1-cpu["sw+mpp"]/cpu["sw+x264"])*100
    }' "$RESULT_TSV"
  echo
  echo " 说明: 'copy' 行为纯 RTP 转发，代表链路的固定开销下限；"
  echo "       'sw+mpp' 与 'mpp+mpp' 的差值即「软件解码」这一项的开销。"
fi
echo "======================================================================"

kill_all
trap - EXIT INT TERM
