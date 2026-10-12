#!/usr/bin/env bash
# 部署 camweb（摄像头硬编码网页测试）到板端并启动
set -e
echo "=== 1. 重启 MediaMTX（启用 HLS/WebRTC）==="
# /root/mediamtx.yml 已由部署脚本上传到位，此处直接重启
systemctl restart mediamtx
sleep 4
systemctl is-active mediamtx || { echo "MediaMTX 未启动"; journalctl -u mediamtx -n 20 --no-pager; exit 1; }
ss -tln | grep -E ':8554|:8888' && echo "  MediaMTX 端口 OK"

echo "=== 2. 安装 camweb ==="
mkdir -p /opt/camweb/static
rm -rf /opt/camweb/static/*
install -m 755 /root/camweb.py /opt/camweb/camweb.py
install -m 644 /root/index.html  /opt/camweb/index.html
install -m 644 /root/hls.min.js  /opt/camweb/static/hls.min.js
install -m 644 /root/camweb.service /etc/systemd/system/camweb.service
systemctl daemon-reload
systemctl enable camweb >/dev/null 2>&1 || true
systemctl restart camweb
sleep 3
systemctl is-active camweb || { echo "camweb 未启动"; journalctl -u camweb -n 20 --no-pager; exit 1; }
echo "  camweb 已启动"
ss -tln | grep -E ':8080' && echo "  端口 8080 OK"
echo "=== 完成 ==="
