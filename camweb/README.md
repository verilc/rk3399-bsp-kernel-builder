# camweb —— RK3399 摄像头采集 / 硬编码 网页测试

在 TN3399_V3（BSP 内核 `6.1.172-rkbsp` + MPP `h264_rkmpp`）上运行的轻量网页。
纯标准库实现，**无需 pip 安装任何包**，复用已就绪的 `ffmpeg-rkmpp` 与 MediaMTX。

## 功能

三种采集 / 编码模式，网页一键切换：

| 模式 | 链路 | 说明 |
|---|---|---|
| `passthrough` | 摄像头 H.264 → `-c copy` → RTSP | 摄像头自带编码，仅转发，**CPU≈5%** |
| `hwenc` | 摄像头 MJPEG → `h264_rkmpp` 硬件编码 → RTSP | **核心验证**：VPU 硬件编码 H.264 |
| `mjpeg` | 摄像头 MJPEG → 本服务 multipart 直出 | 零编码、最低延迟看原始画质 |

* 硬编码 / 直通走 MediaMTX 的 HLS，前端用 hls.js 播放（同源代理避开 CORS）。
* MJPEG 模式走本服务的 `/video/mjpeg`（multipart/x-mixed-replace），前端用 `<img>`。
* 页面实时显示：帧率、码率、ffmpeg 进程 CPU、运行时长、当前 ffmpeg 命令行。

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

打开后：选模式 → 调分辨率/帧率（硬编还可调码率/GOP）→ 点「开始」。
* 硬编/直通：画面经 MediaMTX HLS 延迟约 2–4 秒（HLS 固有缓冲）。
* 想要更低延迟：用 MediaMTX 自带 WebRTC 播放器 `http://<板子IP>:8889/cam/`。

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/camera` | 探测摄像头支持的格式/分辨率/帧率 |
| POST | `/api/start` | body `{mode,width,height,fps,bitrate,gop}` 启动管线 |
| POST | `/api/stop` | 停止 |
| GET | `/api/status` | 运行状态、帧率、码率、CPU、最近日志 |
| GET | `/video/mjpeg` | MJPEG 原生模式的 multipart 视频流 |
| GET | `/hls/<path>` | MediaMTX HLS 同源代理（供 hls.js 使用） |

## 已知事项

* **本板 CPU 当前被限制在 600MHz**（PMIC 调压未接管，与 VPU 硬编无关），所以
  `hwenc` 模式里 MJPEG 软件解码占 ~120% 单核；硬编本身是 VPU 干的，不受此影响。
  若日后修复调频，该模式 CPU 会显著下降。
* `hwenc` 的 fps 统计值是 ffmpeg 内部处理速率，实际输出以 HLS 探测到的 30/1 为准。
* 摄像头节点默认 `/dev/video1`（同时支持 MJPG/H264 1920×1080@30），可在 `camweb.py` 顶部改 `CAM_DEV`。
