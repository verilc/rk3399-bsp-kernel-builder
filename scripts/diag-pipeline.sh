#!/bin/bash
# 找出 1080p MJPEG -> H264 能达到实时 30fps 的最优管线
set -u
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
API=http://127.0.0.1:8080
curl -s -X POST "$API/api/stop" > /dev/null
pkill -x ffmpeg 2>/dev/null
sleep 2

bench() {
  local name="$1"; shift
  echo "########## $name ##########"
  local out
  out=$(timeout 16 $FF -hide_banner -nostdin "$@" -t 8 -f null - 2>&1)
  echo "$out" | grep -E '^frame=' | tail -1
  echo "$out" | grep -iE 'error|invalid|not (found|supported)|failed' | head -3
  echo
}

COMMON_IN=(-f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1)

bench "V1 普通软件解码 (当前 hwenc)" \
  "${COMMON_IN[@]}"

bench "V2 硬解 mjpeg_rkmpp" \
  -c:v mjpeg_rkmpp "${COMMON_IN[@]}"

bench "V3 零拷贝硬解 (hwaccel rkmpp + drm_prime)" \
  -hwaccel rkmpp -hwaccel_output_format drm_prime "${COMMON_IN[@]}"

bench "V4 硬解 + 硬编 h264_rkmpp" \
  -c:v mjpeg_rkmpp "${COMMON_IN[@]}" \
  -c:v h264_rkmpp -rc_mode CBR -b:v 4000k -g 30 -bf 0 -pix_fmt nv12

bench "V5 零拷贝硬解 + 硬编" \
  -hwaccel rkmpp -hwaccel_output_format drm_prime "${COMMON_IN[@]}" \
  -c:v h264_rkmpp -rc_mode CBR -b:v 4000k -g 30 -bf 0

bench "V6 硬解 + 硬编 @720p" \
  -c:v mjpeg_rkmpp -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i /dev/video1 \
  -c:v h264_rkmpp -rc_mode CBR -b:v 3000k -g 30 -bf 0 -pix_fmt nv12

echo "########## media playlist 结构 ##########"
curl -s -X POST -H 'Content-Type: application/json' -d '{"mode":"testpat","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30}' "$API/api/start" > /dev/null
sleep 4
curl -s -o /tmp/master.m3u8 "http://127.0.0.1:8080/hls/cam/index.m3u8"
SUB=$(grep -m1 'm3u8' /tmp/master.m3u8 | tr -d '\r')
curl -s -o /tmp/media.m3u8 "http://127.0.0.1:8080/hls/cam/$SUB"
grep -nE 'gap|EXT-X-PART|EXTINF|^[^#]' /tmp/media.m3u8 | head -25
echo "--- 真实分片(排除 gap.mp4)下载测试 ---"
REALSEG=$(grep -E '^[^#].*\.mp4' /tmp/media.m3u8 | grep -v 'gap.mp4' | head -1 | tr -d '\r')
echo "realseg = $REALSEG"
curl -s -o /tmp/seg.bin -w 'segment HTTP %{http_code} bytes=%{size_download}\n' --max-time 20 "http://127.0.0.1:8080/hls/cam/$REALSEG"
echo "--- ffprobe 该分片 ---"
$FF -hide_banner -v error -i /tmp/seg.bin -f null - 2>&1 | head -3
echo "(ffprobe 无输出=解码正常)"
curl -s -X POST "$API/api/stop" > /dev/null
echo "########## done ##########"
