#!/bin/bash
# camweb 四种模式端到端自检（v2：修正 gap.mp4 误抓、统计真实帧率）
set -u
API=http://127.0.0.1:8080
BODY_HW='{"mode":"hwenc","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30}'
BODY_PT='{"mode":"passthrough","width":1920,"height":1080,"fps":30}'
BODY_MJ='{"mode":"mjpeg","width":1920,"height":1080,"fps":30}'
BODY_TP='{"mode":"testpat","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30}'

check_hls() {
  curl -s -o /tmp/master.m3u8 -w '  master HTTP %{http_code}\n' --max-time 10 "$API/hls/cam/index.m3u8"
  SUB=$(grep -m1 'm3u8' /tmp/master.m3u8 | tr -d '\r')
  if [ -z "$SUB" ]; then echo "  !! 无子列表（流未上线）"; return 1; fi
  curl -s -o /tmp/media.m3u8 -w '  media  HTTP %{http_code}\n' --max-time 10 "$API/hls/cam/$SUB"
  echo "  $(grep -m1 CODECS /tmp/master.m3u8)"
  echo "  LL-HLS parts = $(grep -c 'EXT-X-PART' /tmp/media.m3u8)  segments = $(grep -c 'EXTINF' /tmp/media.m3u8)  gap占位 = $(grep -c '^gap.mp4' /tmp/media.m3u8)"
  # 关键：排除 gap.mp4（那是 MediaMTX 的断流占位，不是真分片）
  SEG=$(grep -E '^[^#].*\.mp4' /tmp/media.m3u8 | grep -v '^gap\.mp4' | head -1 | tr -d '\r')
  echo "  seg = $SEG"
  if [ -n "$SEG" ]; then
    curl -s -o /tmp/seg.bin -w '  segment HTTP %{http_code} bytes=%{size_download}\n' --max-time 20 "$API/hls/cam/$SEG"
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 /tmp/seg.bin 2>/dev/null \
      | while read -r l; do [ -n "$l" ] && echo "  分片解码 OK: $l"; done
  fi
}

run_case() {
  NAME="$1"; BODY="$2"; KIND="$3"
  echo "########## $NAME ##########"
  RES=$(curl -s -X POST -H 'Content-Type: application/json' -d "$BODY" "$API/api/start")
  OK=$(echo "$RES" | grep -o '"ok": *[a-z]*' | head -1)
  if echo "$RES" | grep -q '"ok": false'; then
    echo "  启动失败: $RES"
    echo; return
  fi
  sleep 6
  ST=$(curl -s $API/api/status)
  echo "  运行中=$(echo "$ST" | grep -o '"running": *[a-z]*' | head -1)  fps=$(echo "$ST" | grep -o '"fps": *[0-9.]*' | head -1)  cpu=$(echo "$ST" | grep -o '"cpu": *[0-9.]*' | head -1)"
  if [ "$KIND" = "hls" ]; then
    check_hls
  else
    curl -s --max-time 3 -o /tmp/mj.bin "$API/video/mjpeg" 2>/dev/null
    echo "  mjpeg bytes = $(wc -c < /tmp/mj.bin)  帧头 = $(head -c 12 /tmp/mj.bin | strings | head -1)"
  fi
  curl -s -X POST "$API/api/stop" > /dev/null
  echo "  (stopped)"
  echo
}

run_case "A. 测试图 testpat（免摄像头）" "$BODY_TP" hls
run_case "B. 硬编 hwenc（零拷贝）"       "$BODY_HW" hls
run_case "C. 直通 passthrough"           "$BODY_PT" hls
run_case "D. MJPEG 原生"                 "$BODY_MJ" mjpeg

echo "########## 一致性检查：连续切换模式（验证不再死锁）##########"
for i in 1 2 3; do
  curl -s -o /dev/null -w "  轮$i hwenc->%{http_code} " -X POST -H 'Content-Type: application/json' -d "$BODY_HW" "$API/api/start"
  sleep 2
  curl -s -o /dev/null -w "passthrough->%{http_code} " -X POST -H 'Content-Type: application/json' -d "$BODY_PT" "$API/api/start"
  sleep 1
  echo "status->$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' $API/api/status)"
done
curl -s -X POST "$API/api/stop" > /dev/null
echo "########## done ##########"
