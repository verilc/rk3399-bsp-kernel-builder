#!/bin/bash
# hwenc 路径诊断：软件解码 vs 硬件解码(mjpeg_rkmpp) vs 硬解+硬编
set -u
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
API=http://127.0.0.1:8080

curl -s -X POST "$API/api/stop" > /dev/null
pkill -x ffmpeg 2>/dev/null
sleep 2

echo "########## 1) 软件解码 MJPEG (当前 hwenc 的做法) ##########"
timeout 12 $FF -hide_banner -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1 -t 6 -f null - 2>&1 \
  | grep -E 'frame=.*fps=' | tail -2

echo
echo "########## 2) 硬件解码 MJPEG (mjpeg_rkmpp) ##########"
timeout 12 $FF -hide_banner -c:v mjpeg_rkmpp -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1 -t 6 -f null - 2>&1 \
  | tail -8

echo
echo "########## 3) 硬解 + 硬编 -> RTSP ##########"
timeout 12 $FF -hide_banner -c:v mjpeg_rkmpp -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1 \
  -c:v h264_rkmpp -rc_mode CBR -b:v 4000k -maxrate 4000k -bufsize 8000k -g 30 -bf 0 -pix_fmt nv12 \
  -f rtsp rtsp://127.0.0.1:8554/cam 2>&1 | grep -E 'frame=|Error|error|Invalid' | tail -4

echo
echo "########## 4) HLS 分片下载自检 ##########"
curl -s -X POST -H 'Content-Type: application/json' -d '{"mode":"testpat","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30}' "$API/api/start" > /dev/null
sleep 4
curl -s -o /tmp/master.m3u8 -w 'master HTTP %{http_code}\n' --max-time 10 "$API/hls/cam/index.m3u8"
SUB=$(grep -m1 'm3u8' /tmp/master.m3u8 | tr -d '\r')
echo "sub = $SUB"
curl -s -o /tmp/media.m3u8 -w 'media  HTTP %{http_code}\n' --max-time 10 "$API/hls/cam/$SUB"
SEG=$(grep -m1 -E '^[^#].*\.mp4' /tmp/media.m3u8 | tr -d '\r')
echo "seg = $SEG"
curl -s -o /tmp/seg.bin -w 'segment HTTP %{http_code} bytes=%{size_download}\n' --max-time 20 "$API/hls/cam/$SEG"
ls -la /tmp/seg.bin 2>/dev/null
echo "--- 同一分片直接打 MediaMTX 对比 ---"
curl -s -o /tmp/seg2.bin -w 'direct  HTTP %{http_code} bytes=%{size_download}\n' --max-time 20 "http://127.0.0.1:8888/cam/$SEG"
curl -s -X POST "$API/api/stop" > /dev/null
echo "########## done ##########"
