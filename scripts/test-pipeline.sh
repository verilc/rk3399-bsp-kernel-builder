#!/usr/bin/env bash
# 验证 hw-encode-pipeline.sh serve：RTSP 源 -> 硬解+硬编 -> MediaMTX，再读回校验
exec 2>&1
PIPE=/root/hw-encode-pipeline.sh
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
SYSFF=/usr/bin/ffmpeg
SRC=/root/bench-src-1280x720.mp4
[ -s "$SRC" ] || SRC=/root/e2e-src-1280x720.mp4

cleanup() { pkill -f bench-src >/dev/null 2>&1; pkill -f 'hw-encode-pipeline' >/dev/null 2>&1; sleep 1; }
trap cleanup EXIT
cleanup

echo "=== 1. 起模拟摄像机 -> MediaMTX /src ==="
$SYSFF -hide_banner -loglevel error -nostdin -re -i "$SRC" \
  -c copy -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/src >/tmp/v-src.log 2>&1 &
sleep 4
if ! ss -tln 2>/dev/null | grep -q 8554; then echo "MediaMTX 未运行"; exit 1; fi
echo "源已推送: $(tail -n 2 /tmp/v-src.log)"

echo
echo "=== 2. 用 hw-encode-pipeline.sh serve 转码到 /cam1 ==="
BR=2500 $PIPE serve rtsp://127.0.0.1:8554/src cam1 2500 >/tmp/v-serve.log 2>&1 &
SERVE=$!
sleep 8
if ! kill -0 "$SERVE" 2>/dev/null; then
  echo "serve 启动失败："; tail -n 25 /tmp/v-serve.log; exit 1
fi
echo "serve 已运行 (pid=$SERVE)"
echo "--- serve 日志摘要 ---"
grep -iE '解码|编码|Stream|h264_rkmpp|Input|Output' /tmp/v-serve.log | head -n 12
echo "--- 转码进程 CPU ---"
awk '{printf "utime+stime = %.2f s\n", ($14+$15)/100}' /proc/$SERVE/stat 2>/dev/null

echo
echo "=== 3. 读回 /cam1 并校验 ==="
CPU0=$(awk '{print ($14+$15)/100}' /proc/$SERVE/stat 2>/dev/null)
T0=$(date +%s.%N)
timeout 40 $FF -hide_banner -loglevel error -nostdin -rtsp_transport tcp \
  -i rtsp://127.0.0.1:8554/cam1 -t 20 -c copy -f mpegts -y /tmp/v-cam1.ts
RC=$?
T1=$(date +%s.%N)
CPU1=$(awk '{print ($14+$15)/100}' /proc/$SERVE/stat 2>/dev/null)
echo "录制返回码=$RC"
awk -v a="$CPU0" -v b="$CPU1" -v t0="$T0" -v t1="$T1" 'BEGIN{
  w=t1-t0; c=b-a;
  printf "采样 %0.2f s，转码进程 CPU %.2f s，折合单核占用 %.0f%%\n", w, c, c/w*100
}'
ls -lh /tmp/v-cam1.ts
echo "--- 流信息 ---"
timeout 30 /usr/local/ffmpeg-rkmpp/bin/ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,profile,width,height,avg_frame_rate \
  -of default=nw=1 /tmp/v-cam1.ts
echo "--- 帧数 ---"
timeout 60 /usr/local/ffmpeg-rkmpp/bin/ffprobe -v error -count_frames -select_streams v:0 \
  -show_entries stream=nb_read_frames -of csv=p=0 /tmp/v-cam1.ts
echo "--- 解码错误 ---"
timeout 60 $FF -v error -i /tmp/v-cam1.ts -f null - 2>&1 | head -n 10
echo "(以上为空 = 无错误)"
echo
echo "=== 4. serve 日志尾部 ==="
tail -n 12 /tmp/v-serve.log
echo "=== 完成 ==="
