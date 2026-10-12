#!/bin/bash
# 三种 hwenc 变体的「真实帧率」端到端对比（真实帧 = frame - dup）
set -u
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
API=http://127.0.0.1:8080
curl -s -X POST "$API/api/stop" > /dev/null
pkill -x ffmpeg 2>/dev/null
sleep 2
# 固定高频，排除调频器干扰
for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4; do echo performance > $p/scaling_governor; done
echo "CPU: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq) / $(cat /sys/devices/system/cpu/cpufreq/policy4/scaling_cur_freq) Hz"
echo

run() {
  local name="$1"; shift
  echo "########## $name ##########"
  local log=/tmp/hw_$$.log
  "$FF" -hide_banner -loglevel info "$@" -f rtsp rtsp://127.0.0.1:8554/cam > "$log" 2>&1 &
  local pid=$!
  sleep 20
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  local last
  last=$(grep -oE 'frame= *[0-9]+ fps= *[0-9]+ .*dup=[0-9]+' "$log" | tail -1)
  if [ -z "$last" ]; then
    last=$(grep -E '^frame=' "$log" | tail -1)
  fi
  echo "  统计行: $last"
  # 真实帧率 = (frame - dup) / time
  echo "$log" | grep -oE 'frame= *[0-9]+.*' | tail -1 | \
    awk '{
      f=0;d=0;t=0;
      for(i=1;i<=NF;i++){
        if($i=="frame=") f=$(i+1);
        if($i ~ /^dup=/){ split($i,a,"="); d=a[2] }
        if($i ~ /^time=/){ split($i,a,"="); t=a[2] }
      }
      if(t>0){ printf "  >>> 真实帧率 = (%.0f - %.0f) / %.2f = %.1f fps  |  ffmpeg 显示 %.0f fps\n", f, d, t, (f-d)/t, f/t }
      else print "  (无法解析 time)"
    }'
  echo
}

IN=(-f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 -i /dev/video1)
ENC=(-c:v h264_rkmpp -rc_mode CBR -b:v 4000k -maxrate 4000k -bufsize 8000k -g 30 -bf 0)

run "H1 软件解码 MJPEG + 硬编" "${IN[@]}" "${ENC[@]}" -pix_fmt nv12
run "H2 mjpeg_rkmpp 硬解 + 硬编" -c:v mjpeg_rkmpp "${IN[@]}" "${ENC[@]}" -pix_fmt nv12
run "H3 零拷贝(drm_prime) 硬解 + 硬编" -hwaccel rkmpp -hwaccel_output_format drm_prime "${IN[@]}" "${ENC[@]}"

for p in /sys/devices/system/cpu/cpufreq/policy0 /sys/devices/system/cpu/cpufreq/policy4; do echo schedutil > $p/scaling_governor; done
echo "########## done ##########"
