#!/bin/bash
# =============================================================================
# 将 eMMC 全盘 (mmcblk0) 流式压缩输出到 stdout，可直接重定向到本地文件：
#     plink ... 'bash /root/make-image-stream.sh' > rk3399-tn3399v3.img.zst
#
# 设计要点：
#   * stdout 只承载压缩数据流，所有日志一律走 stderr，避免污染镜像
#   * 输出不落盘到设备本身 —— 否则镜像文件会被写进正在被读取的同一块磁盘，
#     造成「镜像里包含自己的半成品」的污染
#   * 顺手在设备侧算出压缩流的 sha256（tee 分流，不额外读盘），
#     用于和本地收到文件比对，确认传输逐字节无误
# =============================================================================
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

DEV="${DEV:-/dev/mmcblk0}"
LEVEL="${LEVEL:-3}"
HASHFILE="${HASHFILE:-/root/image.zst.sha256}"

TOTAL=$(blockdev --getsize64 "$DEV" 2>/dev/null || echo 0)
log "设备: $DEV  总字节: $TOTAL  zstd 级别: $LEVEL  线程: $(nproc)"

rm -f "$HASHFILE"

log "开始流式读取 + 压缩（输出走 stdout）..."

dd if="$DEV" bs=8M 2>/dev/null \
  | zstd "-$LEVEL" -T0 -q -c \
  | tee >(sha256sum | awk '{print $1}' > "$HASHFILE")

PIPES=("${PIPESTATUS[@]}")
log "管道返回码: dd=${PIPES[0]} zstd=${PIPES[1]} tee=${PIPES[2]}"

# 等 tee 的分支把 hash 写完
for i in $(seq 1 30); do
  [ -s "$HASHFILE" ] && break
  sleep 1
done

if [ -s "$HASHFILE" ]; then
  log "压缩流 sha256 = $(cat "$HASHFILE")"
else
  log "警告: 未能生成 sha256"
fi
log "完成"
