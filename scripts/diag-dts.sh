#!/bin/bash
# 直通流导致 MediaMTX HLS muxer 崩溃（too many reordered frames）——逐个验证修正方案
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg

test_variant() {
  local name="$1"; shift
  echo "########## $name ##########"
  pkill -x ffmpeg 2>/dev/null; sleep 1
  setsid "$FF" -hide_banner -loglevel warning "$@" >/tmp/ff.log 2>&1 < /dev/null &
  sleep 3
  curl -s -o /dev/null --max-time 6 http://127.0.0.1:8888/cam/index.m3u8   # 触发 muxer
  sleep 18
  local n
  n=$(journalctl -u mediamtx -n 60 --no-pager 2>/dev/null | grep -c 'too many reordered')
  echo "  → 'too many reordered' 出现 $n 次"
  journalctl -u mediamtx -n 60 --no-pager 2>/dev/null | grep -E 'muxer cam (destroyed|is converting)' | tail -2 | sed 's/^/    /'
  pkill -x ffmpeg 2>/dev/null
  sleep 1
}

IN="-f v4l2 -input_format h264 -video_size 1920x1080 -framerate 30 -i /dev/video1"

test_variant "V1 当前做法（+genpts + mp4toannexb）" \
  -fflags nobuffer -flags low_delay -fflags +genpts $IN \
  -bsf:v h264_mp4toannexb -c copy -f rtsp rtsp://127.0.0.1:8554/cam

test_variant "V2 去掉 +genpts" \
  -fflags nobuffer -flags low_delay $IN \
  -bsf:v h264_mp4toannexb -c copy -f rtsp rtsp://127.0.0.1:8554/cam

test_variant "V3 setts 强制 30fps 等间隔时间戳" \
  -fflags nobuffer -flags low_delay $IN \
  -bsf:v h264_mp4toannexb,setts=ts=N*3003 -c copy -f rtsp rtsp://127.0.0.1:8554/cam

test_variant "V4 墙钟时间戳" \
  -use_wallclock_as_timestamps 1 -fflags nobuffer $IN \
  -bsf:v h264_mp4toannexb -c copy -f rtsp rtsp://127.0.0.1:8554/cam

echo "===== 全部完成 ====="
