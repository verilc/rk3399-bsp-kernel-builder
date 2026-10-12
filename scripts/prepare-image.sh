#!/usr/bin/env bash
# 制作整机镜像前的准备工作：停掉写入方、刷盘、清缓存
# 注意：不要在本脚本里用 pkill -f 匹配包含自身命令行的关键字
exec 2>&1
echo "--- 1. 停止写入方 ---"
systemctl stop mediamtx 2>/dev/null && echo "mediamtx 已停" || echo "mediamtx 未运行"

# 用精确的进程名匹配，避免 pkill -f 把本脚本自己杀掉
for pat in hw-encode-pipeline.sh hw-encode-bench.sh hw-encode-e2e-test.sh test-pipeline.sh; do
  pkill -f "$pat" 2>/dev/null
done
pkill -x ffmpeg 2>/dev/null
pkill -x ffprobe 2>/dev/null
sleep 2

echo "--- 2. 同步并清缓存 ---"
sync
echo 3 > /proc/sys/vm/drop_caches
sleep 1
sync

echo "--- 3. 磁盘信息 ---"
echo "mmcblk0 字节数: $(blockdev --getsize64 /dev/mmcblk0)"
echo "mmcblk0 扇区数: $(blockdev --getsz /dev/mmcblk0)"
df -h / /boot

echo "--- 4. 当前抢占 CPU 的进程 ---"
ps aux --sort=-%cpu | head -6

echo "--- 5. 内存 ---"
free -m | head -2

echo "--- 6. 残留 ffmpeg 检查 ---"
pgrep -a -x ffmpeg || echo "(无 ffmpeg 残留)"
echo "准备完成"
