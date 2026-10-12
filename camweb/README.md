# camweb —— RK3399 摄像头采集 / 硬编码 网页测试

在 TN3399_V3（BSP 内核 `6.1.172-rkbsp` + MPP `h264_rkmpp`）上运行的轻量网页。
纯标准库实现，**无需 pip 安装任何包**，复用已就绪的 `ffmpeg-rkmpp` 与 MediaMTX。

## 功能

四种采集 / 编码模式，网页一键切换：

| 模式 | 链路 | 实测（1920×1080@30） |
|---|---|---|
| `passthrough` | 摄像头 H.264 → `-c copy` → RTSP | 30fps / **CPU 5%**，画质零损失 |
| `hwenc` | 摄像头 MJPEG → 解码 → `h264_rkmpp` 硬编 | **30fps / CPU ~50%**（软解路径） |
| `mjpeg` | 摄像头 MJPEG → 本服务 multipart 直出 | 30fps / CPU 8%，零编码最低延迟 |
| `testpat` | lavfi 测试图 → `h264_rkmpp` 硬编 | 不接摄像头也能验证整条链路 |

* 硬编 / 直通 / 测试图走 MediaMTX 的 **LL-HLS**，前端用 hls.js 播放（同源代理避开 CORS）。
* MJPEG 模式走本服务的 `/video/mjpeg`（multipart/x-mixed-replace），前端用 `<img>`。
* 页面实时显示：**实际帧率（剔除补帧）**、输出帧率、码率、ffmpeg CPU、运行时长、最近 ffmpeg 日志。

### 帧率统计陷阱（务必注意）
ffmpeg 的 `fps=` 是**补帧后**的输出帧率。源跟不上时 ffmpeg 会插入重复帧凑数，
于是 16fps 的真实处理能力会显示成 27fps，看起来"很正常"。
本服务同时解析 `frame=` / `dup=` / `time=`，算出 **真实帧率 = (frame − dup) / time**，
在页面上单列一格「实际帧率」。所有性能结论都应以它为准。

## 关键设计

### 1. hls.js 本地托管（离线可用）
`static/hls.min.js` 由本服务 `/static/` 提供，**不依赖任何外网 CDN**。
> 早期版本从 `cdn.jsdelivr.net` 加载 hls.js：查看端无外网时 `window.Hls` 为 undefined，
> 播放器根本没装上 → HLS 两个模式全黑屏，而 MJPEG 用的原生 `<img>` 照常出画面。

### 2. 摄像头自动探测
不再硬编码 `/dev/video1`（重新插拔后节点号会变）。启动时扫描 `/dev/video*`，
挑出**支持 MJPG/H264** 的 UVC 节点（自动跳过 `rockchip-rga` 之类的 mem2mem 节点）。
后台每 3s 刷新一次，未找到时只缓存 3s，插回摄像头即可自动恢复。

### 3. hwenc 解码路径可选（性能关键）
`hwenc` 支持三种解码路径，页面可切换，首选失败会自动回退：

| `decode` | 参数 | 真实帧率 @1080p | 说明 |
|---|---|---|---|
| **`sw`（默认）** | — | **30.0 fps** | CPU 软解 MJPEG + VPU 硬编，19.5s 只有 1 帧补帧 |
| `zero` | `-hwaccel rkmpp -hwaccel_output_format drm_prime` | 20.0 fps | 零拷贝，帧留 DMA 缓冲直喂编码器 |
| `hw` | `-c:v mjpeg_rkmpp` | 16.7 fps | VPU 硬解 MJPEG |

> **反直觉但实测如此**：CPU 调频修复前（锁 600MHz）软解只有 12fps，零拷贝(20fps)明显更优；
> 修复后 CPU 到 1.4/1.8GHz，软解直接跑满 30fps，反而超过两条硬解路径——
> 因为 RK3399 的 MJPEG 硬件解码器本身只有 ~17-20fps 产能（VEPU 编码器则有 45fps）。
> 结论：**解码路径的选择取决于 CPU 频率状态**，这里把它做成可切换项而不是写死。

### 4. 启动快速失败 + 错误上屏
`/api/start` 会等 1s 探测 ffmpeg 是否立刻退出（设备不存在 / 被占用 / 格式不支持），
把 stderr 尾部原因直接回给前端显示，而不是让页面以为「已启动」。
日志中的 `mpp[...]` 底层噪声会被过滤掉，只留 ffmpeg 自己的信息行。

### 5. 不会卡死
- 锁用 `RLock`；`stop_pipeline()` 在锁外做进程回收（普通 `Lock` + 嵌套调用会自死锁，
  表现为「已有流在跑时点开始，整个服务永久卡住」）。
- `send_error()` 的消息只用 ASCII（状态行仅允许 latin-1，中文会抛 `UnicodeEncodeError` 并丢连接）。
- MJPEG 长连接在流停止时主动断开，避免连接线程泄漏。

## 运行

服务已通过 systemd 常驻（`camweb.service`，依赖 `mediamtx.service`）：

```bash
systemctl status camweb        # 状态
systemctl restart camweb       # 重启
journalctl -u camweb -f        # 看日志
```

手动运行（调试用）：

```bash
python3 /opt/camweb/camweb.py     # 监听 0.0.0.0:8080
```

## 浏览器访问

```
http://<板子IP>:8080/
```

例：板子在 `10.0.0.18` → `http://10.0.0.18:8080/`

打开后：选模式 → 调分辨率/帧率（硬编/测试图还可调码率、GOP）→ 点「开始」。

* HLS 延迟约 1–2 秒（LL-HLS，`hlsPartDuration 200ms`）。
* 想要更低延迟 / 兜底：MediaMTX 自带 WebRTC 播放器 `http://<板子IP>:8889/cam`（**无需任何 JS 库**）；
  RTSP `rtsp://<板子IP>:8554/cam`。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/camera` | 探测摄像头（`?force=1` 强制重新扫描）；返回 `device/available/formats` |
| POST | `/api/start` | body `{mode,width,height,fps,bitrate,gop}`，mode ∈ passthrough/hwenc/mjpeg/testpat |
| POST | `/api/stop` | 停止 |
| GET | `/api/status` | 运行状态、帧率、码率、CPU、摄像头可用性、最近日志 |
| GET | `/video/mjpeg` | MJPEG 原生模式的 multipart 视频流 |
| GET | `/hls/<path>` | MediaMTX HLS 同源代理（**转发查询串**，LL-HLS 阻塞式重载依赖 `?_HLS_msn=`） |
| GET | `/static/<file>` | 静态资源（本地 hls.js） |

## 部署

```bash
# 本地 → 板端
bash scripts/dev.sh put camweb/camweb.py   /root/camweb.py
bash scripts/dev.sh put camweb/index.html  /root/index.html
bash scripts/dev.sh put camweb/static/hls.min.js /root/hls.min.js
bash scripts/dev.sh put scripts/mediamtx.yml /root/mediamtx.yml
# 板端安装
bash /root/deploy-camweb.sh
```

## 自检

```bash
bash scripts/check-hls.sh          # HLS 主/子播放列表 + 分片下载 + LL-HLS 特征
bash scripts/test-camweb-modes.sh  # 四模式端到端 + 连续切换防死锁
bash scripts/diag-pipeline.sh      # 各解码/编码方案帧率对比
```

## 已知事项

### 2026-10-12 晚：直通黑屏根因（务必记住）

**`-fflags +genpts` 会让直通流打挂 MediaMTX 的 HLS 切片器**：

```
[HLS] [muxer cam] destroyed: muxer error: unable to extract DTS: too many reordered frames (14)
```

切片器一崩，HLS 播放列表 404，浏览器黑屏（但 ffmpeg 侧统计照常显示，极具迷惑性）。
**修复：直通/所有模式都不要再加 `+genpts`**（`HDR` 里已移除并留了注释）。
实测去掉后 muxer 稳定，`too many reordered` 不再出现。
（备选方案 `setts=ts=N*3003` 强制等间隔时间戳、`-use_wallclock_as_timestamps 1` 也有效。）

**HLS 播放链路优先级**：浏览器 → MediaMTX `:8888`（直连，MediaMTX 原生回显 Origin 的 CORS 头）；
直连失败自动切同源代理 `/hls/`。代理必须"永不裸崩"——曾因 `except` 分支用了未 import 的
`sys`，上游 404 时异常处理器自己 `NameError`，连接被裸关闭 → 浏览器 `ERR_EMPTY_RESPONSE`
→ hls.js 致命网络错误 → 黑屏。**页面若改过，记得强刷（Ctrl+F5），Chrome 会缓存旧 HTML。**

**低延迟播放**：默认走 **WebRTC（MediaMTX WHEP `:8889/cam/whep`）**，实测端到端
jitter buffer 延迟 **~22ms**，HLS(LL-HLS) 约 1.5s。

### 码控

实测（1920x1080@30，同一 8s 摄像头源离线编码）：

| 码控 | 结果 |
|---|---|
| CBR 4000k | q≈30~35，偏软（默认 4M 对 1080p 明显不够） |
| CBR 8000k | q≈28 |
| **CQP 23** | **q≈23，明显更清晰**，吞吐相同（37~38fps） |

所以页面默认 **CQP qp=24**（质量优先），需要恒定码率时切 CBR（默认提到 8000k）。

### 其它

* **CPU 调频已修复**（2026-10-12）：根因是 RK808 regulator 驱动 `id_table` 漏了 `"rk808-regulator"`，
  驱动不绑定 → `vdd_cpu_l` 未注册 → cpufreq 锁死 U-Boot 默认 600MHz。
  新内核已部署并重启验证：`vdd_cpu_l` 电压 925mV/enabled，
  小核可到 1416MHz、大核到 1800MHz（`schedutil`）。此前 12fps 的 MJPEG 软解现为 30fps。
* 硬编 sw 路径**不再指定 `-pix_fmt nv12`**：ffmpeg 直接把 `yuvj420p` 喂给 h264_rkmpp
  （它支持），省掉一次 swscale 全帧拷贝。
* 摄像头若在 USB 总线上掉线（`dmesg` 可见 `device descriptor read/64, error -110`），
  `/dev/video*` 会消失，页面会明确提示「未检测到摄像头」，重新插拔即可。
* LL-HLS 播放列表在流刚起步时会出现若干 `gap.mp4` 占位行（表示历史窗口尚无分片），
  属正常现象，跑满 7 个分片后消失；做分片自检时需排除 `gap.mp4`。
* 板端 `/usr/local/ffmpeg-rkmpp/bin/ffmpeg` 支持 `h264/hevc/mjpeg/…_rkmpp` 解码与
  `h264/hevc/mjpeg_rkmpp` 编码；**没有 `rkrga` 滤镜**，所以缩放只能走 CPU。
* RK3399 VEPU（H.264 编码器）实测产能约 45fps@1080p，**不是**当前瓶颈。
* 浏览器侧验收用 `scripts/probe-page.mjs`（本机无头 Chrome + CDP，自动点「开始」，
  抓 hls.js/控制台报错、`<video>` 状态与截图），比 curl 自检更接近真实体验。
