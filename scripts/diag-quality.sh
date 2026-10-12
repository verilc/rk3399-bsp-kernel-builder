#!/bin/bash
FF=/usr/local/ffmpeg-rkmpp/bin/ffmpeg
echo "=== camweb 代理报错日志 ==="
journalctl -u camweb -n 200 --no-pager 2>/dev/null | grep -iE "proxy failed|Traceback|Error" | tail -8

echo
echo "=== 录 8s 固定 MJPEG 源 ==="
$FF -hide_banner -loglevel error -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 \
    -i /dev/video1 -t 8 -c copy -f mjpeg /tmp/src.mjpg
ls -la /tmp/src.mjpg

run() {
  echo "----- $1 -----"
  shift
  timeout 90 $FF -hide_banner -loglevel info -i /tmp/src.mjpg "$@" -f null - 2>&1 \
    | grep -E '^frame=' | tail -1
  echo "  输出流: $(timeout 90 $FF -hide_banner -loglevel info -i /tmp/src.mjpg "$@" -f null - 2>&1 | grep -oE 'Video: h264 \(High\), [a-z0-9_]+\(pc[^)]*\)' | head -1)"
}

echo
echo "=== A: 软解 + 显式 nv12（当前做法） ==="
run "A nv12"  -c:v h264_rkmpp -rc_mode CBR -b:v 8000k -g 30 -bf 0 -pix_fmt nv12
echo "=== B: 软解 + 自动选格式（跳过 swscale） ==="
run "B auto"  -c:v h264_rkmpp -rc_mode CBR -b:v 8000k -g 30 -bf 0
echo "=== C: VBR 8000k ==="
run "C vbr"   -c:v h264_rkmpp -rc_mode VBR -b:v 8000k -maxrate 12000k -bufsize 8000k -g 30 -bf 0 -pix_fmt nv12
echo "=== D: CQP qp=23 ==="
run "D cqp"   -c:v h264_rkmpp -rc_mode CQP -qp_init 23 -g 30 -bf 0 -pix_fmt nv12
echo "=== 完成 ==="
