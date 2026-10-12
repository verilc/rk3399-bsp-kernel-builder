#!/bin/bash
# 现场诊断：直通不出画面 / 硬编帧率延迟清晰度
API=http://127.0.0.1:8080
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
FP=/usr/local/ffmpeg-rkmpp/bin/ffprobe

echo "===== 1. 基础状态 ====="
echo -n "services: "; systemctl is-active mediamtx camweb | tr '\n' ' '; echo
echo -n "camera:  "; curl -s --max-time 6 $API/api/camera; echo
echo "--- cpufreq ---"
for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4; do
  echo "  $p cur=$(cat $p/scaling_cur_freq 2>/dev/null) gov=$(cat $p/scaling_governor 2>/dev/null) max=$(cat $p/scaling_max_freq 2>/dev/null)"
done
echo "--- 摄像头原生能力 ---"
v4l2-ctl -d /dev/video1 --list-formats-ext 2>/dev/null | sed -n '1,60p'

echo
echo "===== 2. h264_rkmpp 编码器参数 ====="
$FF -hide_banner -h encoder=h264_rkmpp 2>&1 | sed -n '1,70p'

echo
echo "===== 3. 直通模式 ====="
curl -s -X POST -H 'Content-Type: application/json' -d '{"mode":"passthrough","width":1920,"height":1080,"fps":30}' $API/api/start; echo
sleep 9
echo "--- status ---"; curl -s $API/api/status; echo
echo "--- master playlist ---"
curl -sL --max-time 8 $API/hls/cam/index.m3u8
echo "--- rtsp 直探（MediaMTX 分发出来的流） ---"
timeout 20 $FP -v error -select_streams v:0 -show_entries stream=codec_name,profile,level,width,height,r_frame_rate,avg_frame_rate,has_b_frames -of default=nw=1 rtsp://127.0.0.1:8554/cam 2>&1 | head -20
echo "--- 6 秒内 I 帧数量（关键帧间隔） ---"
timeout 25 $FF -hide_banner -loglevel info -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -t 6 -vf "select='eq(pict_type,I)'" -vsync 0 -f null - 2>&1 | grep -E '^frame=' | tail -1
echo "--- 6 秒内总帧数 ---"
timeout 25 $FF -hide_banner -loglevel info -rtsp_transport tcp -i rtsp://127.0.0.1:8554/cam -t 6 -an -f null - 2>&1 | grep -E '^frame=' | tail -1

echo
echo "===== 4. 拉一个真实 HLS 分片并解码验证 ====="
curl -sL --max-time 8 -o /tmp/sub.m3u8 "$API/hls/cam/index.m3u8"
SUB=$(grep -v '^#' /tmp/sub.m3u8 | grep m3u8 | head -1)
echo "sub=$SUB"
if [ -n "$SUB" ]; then
  curl -sL --max-time 8 -o /tmp/media.m3u8 "$API/hls/cam/$SUB"
  echo "--- media playlist 头 ---"; head -25 /tmp/media.m3u8
  SEG=$(grep -v '^#' /tmp/media.m3u8 | grep -v gap.mp4 | grep -E '\.(mp4|ts)' | head -3 | tail -1)
  echo "seg=$SEG"
  if [ -n "$SEG" ]; then
    curl -sL --max-time 15 -o /tmp/seg.bin "$API/hls/cam/$SEG"
    ls -la /tmp/seg.bin
    echo "--- ffprobe 分片 ---"
    timeout 15 $FP -v error -show_entries stream=codec_name,profile,level,width,height,r_frame_rate -of default=nw=1 /tmp/seg.bin 2>&1 | head -12
    echo "--- 解码分片（看能否解出帧） ---"
    timeout 20 $FF -hide_banner -loglevel error -i /tmp/seg.bin -f null - 2>&1 | head -8
    echo "decode_exit=$?"
  fi
fi
curl -s -X POST $API/api/stop >/dev/null

echo
echo "===== 5. 硬编模式 ====="
curl -s -X POST -H 'Content-Type: application/json' -d '{"mode":"hwenc","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30,"decode":"sw"}' $API/api/start; echo
sleep 15
echo "--- status(sw) ---"; curl -s $API/api/status; echo
curl -s -X POST $API/api/stop >/dev/null; sleep 2
curl -s -X POST -H 'Content-Type: application/json' -d '{"mode":"hwenc","width":1920,"height":1080,"fps":30,"bitrate":4000,"gop":30,"decode":"zero"}' $API/api/start; echo
sleep 15
echo "--- status(zero) ---"; curl -s $API/api/status; echo
curl -s -X POST $API/api/stop >/dev/null
echo "===== 诊断结束 ====="
