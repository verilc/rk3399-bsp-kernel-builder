#!/bin/bash
# 板端 HLS 链路自检（走 camweb 代理，模拟浏览器行为）
set -u
BASE=http://127.0.0.1:8080/hls/cam
echo "=== 1. master playlist (via proxy) ==="
curl -s -o /tmp/master.m3u8 -w 'HTTP %{http_code} bytes=%{size_download}\n' --max-time 10 "$BASE/index.m3u8"
cat /tmp/master.m3u8
SUB=$(grep -m1 'm3u8' /tmp/master.m3u8 | tr -d '\r')
echo "--- sub = $SUB"
if [ -z "$SUB" ]; then echo "!! 拿不到子列表"; exit 1; fi

echo "=== 2. media playlist (via proxy) ==="
curl -s -o /tmp/media.m3u8 -w 'HTTP %{http_code} bytes=%{size_download}\n' --max-time 10 "$BASE/$SUB"
head -30 /tmp/media.m3u8
echo "=== 3. LL-HLS 特征 ==="
echo "EXT-X-PART 数量      : $(grep -c 'EXT-X-PART' /tmp/media.m3u8)"
echo "独立分片(EXTINF)数量 : $(grep -c 'EXTINF' /tmp/media.m3u8)"
echo "SERVER-CONTROL       : $(grep -c 'SERVER-CONTROL' /tmp/media.m3u8)"
echo "=== 4. 抓一个分片验证可下载 ==="
SEG=$(grep -m1 -E '^[^#].*\.(mp4|ts)' /tmp/media.m3u8 | tr -d '\r')
PART=$(grep -m1 'EXT-X-PART' /tmp/media.m3u8 | sed -n 's/.*URI="\([^"]*\)".*/\1/p')
echo "first segment = $SEG"
echo "first part    = $PART"
[ -n "$SEG" ] && curl -s -o /dev/null -w "segment HTTP %{http_code} bytes=%{size_download}\n" --max-time 10 "$BASE/$SEG"
[ -n "$PART" ] && curl -s -o /dev/null -w "part    HTTP %{http_code} bytes=%{size_download}\n" --max-time 10 "$BASE/$PART"
echo "=== end ==="
