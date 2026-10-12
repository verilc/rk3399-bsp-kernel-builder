#!/bin/bash
# 直通 vs 硬编：HLS 播放链路逐项对比
API=http://127.0.0.1:8080
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
FP=/usr/local/ffmpeg-rkmpp/bin/ffprobe
D=/tmp/camweb-dl
rm -rf $D; mkdir -p $D

start() { curl -s -X POST -H 'Content-Type: application/json' -d "$1" $API/api/start >/dev/null 2>&1; }
stop()  { curl -s -X POST $API/api/stop >/dev/null 2>&1; }

dump() {
  echo "########## $1 ##########"
  echo "--- status ---"; curl -s --max-time 6 $API/api/status | head -c 500; echo
  # 预热一次，让 MediaMTX 的 HLS muxer 启动
  curl -sL --max-time 10 "$API/hls/cam/index.m3u8" >/dev/null 2>&1
  sleep 10
  curl -sL --max-time 10 "$API/hls/cam/index.m3u8" > $D/master.m3u8
  echo "--- master playlist ---"; cat $D/master.m3u8
  echo "--- master CODECS 行 ---"; grep -o 'CODECS="[^"]*"' $D/master.m3u8
  SUB=$(grep -v '^#' $D/master.m3u8 | grep m3u8 | head -1)
  echo "SUB=$SUB"
  [ -z "$SUB" ] && return
  curl -sL --max-time 10 "$API/hls/cam/$SUB" > $D/media.m3u8
  echo "--- media playlist（完整） ---"; cat $D/media.m3u8
  echo "--- 统计 ---"
  echo "条目 seg=$(grep -cE '^[^#].*\.mp4' $D/media.m3u8) part=$(grep -c 'EXT-X-PART:' $D/media.m3u8) gap=$(grep -c 'EXT-X-GAP' $D/media.m3u8)"
  MAP=$(grep 'EXT-X-MAP' $D/media.m3u8 | sed 's/.*URI="//;s/".*//')
  SEG=$(grep -v '^#' $D/media.m3u8 | grep -v 'gap.mp4' | grep -E '\.mp4' | tail -1)
  echo "MAP=$MAP"; echo "SEG=$SEG"
  if [ -n "$MAP" ] && [ -n "$SEG" ]; then
    curl -sL --max-time 15 -o $D/init.mp4 "$API/hls/cam/$MAP"
    curl -sL --max-time 15 -o $D/seg.mp4  "$API/hls/cam/$SEG"
    ls -la $D/init.mp4 $D/seg.mp4
    cat $D/init.mp4 $D/seg.mp4 > $D/joined.mp4
    echo "--- ffprobe init+seg ---"
    timeout 20 $FP -v error -show_entries stream=codec_name,profile,level,width,height,r_frame_rate,extradata_size -of default=nw=1 $D/joined.mp4 2>&1 | head
    echo "--- 解码 init+seg（能解出多少帧） ---"
    timeout 25 $FF -hide_banner -loglevel info -i $D/joined.mp4 -f null - 2>&1 | grep -E '^frame=|rror' | tail -3
  fi
  echo
}

echo "===== A. H.264 直通 ====="
start '{"mode":"passthrough","width":1920,"height":1080,"fps":30}'
sleep 3
dump "passthrough"
stop; sleep 2

echo "===== B. H.264 硬编（sw） ====="
start '{"mode":"hwenc","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30,"decode":"sw"}'
sleep 3
dump "hwenc-sw"
stop

echo "===== mediamtx 日志（近 40 行） ====="
journalctl -u mediamtx -n 40 --no-pager 2>/dev/null | tail -40
echo "===== 结束 ====="
