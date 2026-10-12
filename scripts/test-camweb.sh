#!/usr/bin/env bash
# 端到端验证 camweb 三种模式（含模式间冷却间隔）
FF=http://127.0.0.1:8080
start() {
  echo "### 启动模式: $1"
  curl -s -X POST "$FF/api/start" -H 'Content-Type: application/json' \
    -d "{\"mode\":\"$1\",\"width\":1920,\"height\":1080,\"fps\":30,\"bitrate\":4000,\"gop\":30}" >/dev/null
  sleep 10
  echo "### 状态"
  curl -s "$FF/api/status" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  running=',d['running'],'mode=',d['mode'],'fps=',d['fps'],'kbps=',d['kbps'],'cpu=',d['cpu'],'err=',d['error'])"
}
stop() { curl -s -X POST "$FF/api/stop" >/dev/null; sleep 4; }

check_hls() {
  echo "### 探测 HLS 码流 (http://127.0.0.1:8888/cam)"
  ffprobe -v error -show_entries stream=codec_name,width,height,avg_frame_rate -of csv=p=0 \
    "http://127.0.0.1:8888/cam/index.m3u8" 2>&1 | sed 's/^/  /'
  echo "  m3u8 首行:"; curl -s "http://127.0.0.1:8080/hls/cam/index.m3u8" | head -c 160 | sed 's/^/  /'; echo
}
check_mjpeg() {
  echo "### 抓取 MJPEG 帧（应看到 ffd8 JPEG 头）"
  curl -s --max-time 4 "http://127.0.0.1:8080/video/mjpeg" | head -c 16 | od -A x -t x1z | head -2 | sed 's/^/  /'
}

start hwenc;       check_hls;  stop
start passthrough;  check_hls;  stop
start mjpeg;       check_mjpeg; stop
echo "### 全部完成，已停止"
