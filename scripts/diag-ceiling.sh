#!/bin/bash
# 1) 摄像头 MJPEG 采集上限  2) 零拷贝硬编实stream稳定性与CPU  3) VPU/RGA 时钟
set -u
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
API=http://127.0.0.1:8080
curl -s -X POST "$API/api/stop" > /dev/null
pkill -x ffmpeg 2>/dev/null
sleep 2

echo "########## 0) 时钟 ##########"
for f in /sys/kernel/debug/clk/clk_summary; do
  [ -r "$f" ] && grep -iE 'vpu|venc|vdec|rga|aclk_ddr|clk_ddr|cpll|gpll|aclk_vio' "$f" | head -20
done
echo "--- cpu freq ---"
for c in 0 4; do echo -n "cpu$c: "; cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null || echo "N/A"; done
echo

echo "########## 1) 摄像头 MJPEG 原始采集上限 (-c copy, 8s) ##########"
timeout 14 $FF -hide_banner -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1 -c copy -t 8 -f null - 2>&1 | grep -E '^frame=' | tail -1
echo

echo "########## 2) 摄像头 H264 原始采集上限 (-c copy, 8s) ##########"
timeout 14 $FF -hide_banner -f v4l2 -input_format h264 -video_size 1920x1080 -framerate 30 -i /dev/video1 -c copy -t 8 -f null - 2>&1 | grep -E '^frame=' | tail -1
echo

echo "########## 3) 零拷贝硬编 实际推流 20s（测稳定性/CPU）##########"
$FF -hide_banner -loglevel warning \
  -hwaccel rkmpp -hwaccel_output_format drm_prime \
  -f v4l2 -thread_queue_size 512 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1 \
  -c:v h264_rkmpp -rc_mode CBR -b:v 4000k -maxrate 4000k -bufsize 8000k -g 30 -bf 0 \
  -f rtsp rtsp://127.0.0.1:8554/cam &
PID=$!
sleep 2
R1=$(awk '{print $14+$15}' /proc/$PID/stat 2>/dev/null || echo 0)
SLEEP_S=15
sleep $SLEEP_S
R2=$(awk '{print $14+$15}' /proc/$PID/stat 2>/dev/null || echo 0)
CLK=$(getconf CLK_TCK)
CPU=$(awk -v a="$R1" -v b="$R2" -v s="$SLEEP_S" -v c="$CLK" 'BEGIN{printf "%.1f", (b-a)/c/s*100}')
echo "零拷贝硬编 ffmpeg CPU = ${CPU}%  (单核百分比)"
echo -n "进程存活: "; kill -0 $PID 2>/dev/null && echo YES || echo "NO(已退出)"
echo "--- HLS 侧检查 ---"
curl -s -o /tmp/master.m3u8 -w 'master HTTP %{http_code}\n' --max-time 10 "http://127.0.0.1:8080/hls/cam/index.m3u8"
grep -m1 CODECS /tmp/master.m3u8
kill $PID 2>/dev/null
sleep 1
echo

echo "########## 4) RGA 缩放可用性 (1080p->720p) ##########"
$FF -hide_banner -filters 2>/dev/null | grep -iE 'rkrga|scale_rkrga' || echo "(无 rkrga filter)"
echo "########## done ##########"
