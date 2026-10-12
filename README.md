# RK3399 BSP 内核构建器（TN3399_V3 + MPP 硬件编码）

用 **GitHub Actions 的免费 arm64 runner** 编译 **Rockchip 厂商(BSP)内核**，为
`TIANNUO TN3399_V3`（RK3399）打开 **MPP 硬件编解码**——也就是本机上一直缺的
**H.264 硬件编码器（VEPU2）**。

> 不需要本地电脑参与编译。全程在 GitHub 云端跑，产物直接发布成 Release 资产，
> 设备上用 `curl` 就能下载。

---

## 一、为什么要自己编

| 事实 | 说明 |
|---|---|
| RK3399 芯片**支持** H.264 硬编码 | 硬件 VEPU2 单元，1080p@30 |
| 当前系统用的是 mainline 内核 | `6.18.x-ophub`，开源 `hantro` 驱动**只实现了 JPEG 编码器** |
| Armbian 仓库里没有 rk3399 的 BSP 内核 | `linux-image-legacy-rockchip64` 已被上游删除 |
| ophub 的现成工作流也编不出来 | 它只编**主线**内核（unifreq/ophub 的 `linux-6.x.y`），那棵树里没有 `drivers/video/rockchip/mpp` |
| GitHub 免费 arm64 runner | 公开仓库免费、不限分钟数 → 正好用来编 |

结论：**只有自己编 Rockchip BSP 内核这一条路**，而 GitHub Actions 是最省事的编译场地。

---

## 二、这个仓库做了什么

```
.
├── .github/workflows/build-kernel.yml   # 构建工作流（跑在 ubuntu-24.04-arm）
├── dts/rk3399-tn3399-v3.dts             # TN3399_V3 设备树（已含 MPP 节点使能）
├── config/rockchip-armbian.fragment     # 在 BSP defconfig 上补齐 Armbian/Docker/WiFi 选项
├── config/rockchip-minimal.fragment     # 可选：关掉无关子系统以缩短编译时间
├── scripts/deploy-on-device.sh          # 设备侧安装脚本（带备份）
├── scripts/rollback.sh                  # 设备侧回滚脚本
├── scripts/hw-encode-pipeline.sh        # ★ 硬编转码推流主脚本
├── scripts/hw-encode-bench.sh           # 四模式 CPU 开销对比基准
├── scripts/hw-encode-e2e-test.sh        # 单模式端到端链路验证
├── scripts/test-pipeline.sh             # serve 子命令的自动化验证
├── scripts/mediamtx.yml                 # 本机 RTSP/RTMP 服务配置（测试用）
├── scripts/mediamtx.service             # MediaMTX 的 systemd 单元
└── scripts/dev.sh                       # 本机连板子跑命令/传文件的小工具
```

工作流做这几件事：

1. 腾磁盘空间，选一个空间最大的分区当编译目录
2. 浅克隆 `rockchip-linux/kernel` 的 `develop-6.1` 分支
3. 把 `dts/rk3399-tn3399-v3.dts` 装进 `arch/arm64/boot/dts/rockchip/` 并挂到 Makefile
4. `make ARCH=arm64 rockchip_linux_defconfig` + 合并配置片段 + `olddefconfig`
5. **自检关键配置**（MPP / VEPU2 / IOMMU / UVC / overlayfs / 模块签名），不通过就失败退出
6. `make Image dtbs modules`（带 ccache 缓存，重跑很快）
7. 打包成 `rk3399-bsp-<版本>-tn3399.tar.zst` + sha256，上传 Artifact 并发布 Release

### 关于设备树的关键点

`rk3399-tn3399-v3.dts` 是在 unifreq 维护的权威版本基础上，**表头加了 9 个节点的使能**：

```dts
&mpp_srv { status = "okay"; };   /* MPP 服务框架 */
&vepu    { status = "okay"; };   /* ★ H.264 编码器 */
&vdpu    { status = "okay"; };   /* 解码器 */
&rkvdec  { status = "okay"; };   /* 4K 解码器 */
&iep     { status = "okay"; };   /* 反交错 */
&rga     { status = "okay"; };   /* 2D 加速 */
...
```

这些节点在 BSP 的 `rk3399.dtsi` 里**已全部定义好**（默认 `disabled`），所以移植量就是打开开关。
`TN3399_V3` 本质是 VAMRS ROCK960 的衍生板，而 BSP 树里自带 rock960 支持，兼容性良好。

### 关于内核配置的关键点

`rockchip_linux_defconfig` **自带** `CONFIG_ROCKCHIP_MPP_SERVICE=y` / `ROCKCHIP_MPP_VEPU2=y`
等 MPP 选项，但实测**缺少**以下内容，不补的话新内核能起来但功能残缺：

- `CONFIG_OVERLAY_FS` —— Docker 存储驱动必需
- `CONFIG_BRCMFMAC` —— 板载 WiFi（BCM43455）不可用
- `CONFIG_VETH` / `NF_CONNTRACK` / `BRIDGE` —— Docker 网络不可用
- 还有 RTC、蓝牙、`COMPAT`、cgroup 系列等

这些都在 `config/rockchip-armbian.fragment` 里补齐了。

---

## 三、怎么用

### 1. 建仓库并推送

必须是 **公开仓库**——arm64 runner 仅在公开仓库免费可用，私有仓库会直接失败
（报 "The self-hosted runner ... arm64 is not supported"）。仓库里只有 DTS、配置片段
和工作流，**不含任何敏感信息**。

用令牌推送（HTTPS）：

```bash
git init -b main
git add -A
git commit -m "RK3399 TN3399_V3 BSP kernel builder with MPP"
git remote add origin https://github.com/<你的用户名>/rk3399-bsp-kernel-builder.git
git push -u origin main
```

#### 需要的令牌权限

用 **Fine-grained personal access token**（细粒度令牌），作用域只选这一个仓库：

| 权限 | 级别 | 用途 |
|---|---|---|
| `Contents` | Read and write | 推送代码、创建 Release |
| `Workflows` | Read and write | **必需**——推送 `.github/workflows/` 下的文件必须带这个权限 |
| `Metadata` | Read | 自动附带，必选 |

推送时把令牌当密码用：

```bash
git remote set-url origin https://<你的用户名>:<令牌>@github.com/<你的用户名>/rk3399-bsp-kernel-builder.git
git push -u origin main
```

> GitHub 的**账号密码不能用于 git push**（2021 年 8 月起已停用），必须用令牌或 SSH 密钥。

### 2. 触发构建

工作流**没有配 push 自动触发**——一次编译要 1~3 小时，避免误提交就烧掉一次。

到 **Actions → Build Rockchip BSP kernel (TN3399_V3 / RK3399 + MPP) → Run workflow** 点一下，
第一次用默认参数即可：

| 参数 | 默认值 | 说明 |
|---|---|---|
| `kernel_repo` | `rockchip-linux/kernel` | BSP 内核仓库 |
| `kernel_branch` | `develop-6.1` | 推荐 6.1（对新绑定的支持比 4.4 好很多） |
| `localversion` | `-rkbsp` | 内核版本后缀 |
| `make_jobs` | 空 = nproc | 并行数 |
| `keep_minimal` | **true** | 关掉 ISP/ISP 等无关子系统，**首次先验证能否点亮**；确认能启动后用 `false` 重编一次拿完整功能 |

也可以用 `workflow_dispatch` API 触发：

```bash
curl -X POST \
  -H "Authorization: Bearer <令牌>" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/<用户名>/rk3399-bsp-kernel-builder/actions/workflows/build-kernel.yml/dispatches \
  -d '{"ref":"main","inputs":{"kernel_branch":"develop-6.1","keep_minimal":"true"}}'
```


整个编译大约需要 **1~3 小时**（首次）。工作流设置了 355 分钟超时。

### 3. 下载产物到设备

构建成功后会自动创建 Release，资产形如：

```
rk3399-bsp-6.1.xxx-rkbsp-tn3399.tar.zst
rk3399-bsp-6.1.xxx-rkbsp-tn3399.tar.zst.sha256
```

在设备上直接下：

```bash
cd /root
curl -fLO https://github.com/<你的用户名>/rk3399-bsp-kernel-builder/releases/download/bsp-<版本>/<文件名>
curl -fLO https://github.com/<你的用户名>/rk3399-bsp-kernel-builder/releases/download/bsp-<版本>/<文件名>.sha256
```

### 4. 部署（设备侧）

```bash
bash deploy-on-device.sh /root/rk3399-bsp-6.1.xxx-rkbsp-tn3399.tar.zst
reboot
```

脚本会自动备份当前 `/boot` 到 `/root/kernel-rollback/<时间戳>/`，
并且**不删除旧内核的模块目录**，所以回滚很干净。

### 5. 验证

```bash
uname -r                            # 新的内核版本
ls -l /dev/mpp_service              # ★ 出现即 MPP 驱动就绪
dmesg | grep -iE 'mpp|vepu|vpu'     # 编码器探测日志
```

接下来编译用户态库并做实测：

```bash
git clone -b develop --depth=1 https://github.com/rockchip-linux/mpp.git
cd mpp && mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DHAVE_DRM=ON
make -j$(nproc)
# 编码器自检
./test/mpi_enc_test -t 7 -w 1920 -h 1080 -n 200 -o /tmp/out.h264
ffprobe /tmp/out.h264
```

> **注意**：MPP 仓库里的 `build/` 目录**不能被删**——`build/cmake/merge_objects.cmake`
> 是构建系统的一部分，删掉再 cmake 会报 `Unknown CMake command "merge_objects"`。
> 正确做法是 **out-of-source** 构建（如上，在源码树外的目录里 cmake）。

#### ffmpeg 必须用带 rkmpp 编码器的那一份

**上游 FFmpeg 只有 rkmpp 解码器**（`libavcodec/rkmppdec.c`），**没有编码器**——
用官方 FFmpeg 会得到 `Unknown encoder 'h264_rkmpp'`。编码器只存在于社区维护的分支
[`nyanmisaka/ffmpeg-rockchip`](https://github.com/nyanmisaka/ffmpeg-rockchip)：

```bash
git clone -b main --depth=1 https://github.com/nyanmisaka/ffmpeg-rockchip.git
cd ffmpeg-rockchip
./configure --prefix=/usr/local/ffmpeg-rkmpp --enable-rkmpp --enable-version3 \
            --enable-libdrm --enable-gpl --disable-doc
make -j$(nproc) && make install
# 验证
/usr/local/ffmpeg-rkmpp/bin/ffmpeg -encoders | grep rkmpp
#  V..... h264_rkmpp   Rockchip MPP (Media Process Platform) H264 encoder
#  V..... hevc_rkmpp   ... HEVC encoder
#  V..... mjpeg_rkmpp  ... MJPEG encoder
```

`rkmpp` 属于 "version3" 组件，`--enable-version3` 不加会直接 configure 失败。

### 6. 回滚

```bash
bash rollback.sh --list     # 看有哪些时间点
bash rollback.sh            # 回滚到最近一次部署前
```

---

## 四、实测结果（已跑通）

### 4.1 内核与驱动

```
$ uname -r
6.1.172-rkbsp

$ dmesg | grep -iE 'mpp|vepu'
mpp-srv ff650000.mpp-srv: probing finish
mpp_vepu2 ff650000.vepu: probing finish      <- ★ H.264 编码器就绪

$ ls -l /dev/mpp_service
crw------- 1 root root 240, 0 /dev/mpp_service
```

网卡、eMMC、温控、调频均正常（空载 27.5 °C）。

### 4.2 四模式 CPU 开销对比

链路：模拟摄像机 → MediaMTX(`/src`) → **转码** → MediaMTX(`/out`) → 录制校验。
「转码进程 CPU」= 该进程自身的 `utime+stime`，与链路里其它进程无关。
`copy` 行为纯 RTP 转发，代表链路固定开销的下限。

**1280x720@30**

| 方式 | 实际帧率 | CPU 时间 | 单核占用 | 每帧 CPU | 峰值内存 |
|---|---|---|---|---|---|
| `copy`（纯转发） | 29.6 fps | 0.74 s | 4 % | 1.23 ms | 20 MB |
| **`mpp+mpp`（硬解+硬编）** | **27.8 fps** | **7.83 s** | **39 %** | **13.93 ms** | **22 MB** |
| `sw+mpp`（软解+硬编） | 27.5 fps | 18.33 s | 91 % | 33.03 ms | 51 MB |
| `sw+x264`（软解+软编） | 29.2 fps | 50.00 s | 248 % | 85.03 ms | 112 MB |

**1920x1080@30**

| 方式 | 实际帧率 | CPU 时间 | 单核占用 | 每帧 CPU | 峰值内存 |
|---|---|---|---|---|---|
| `copy`（纯转发） | 29.4 fps | 0.86 s | 6 % | 1.92 ms | 28 MB |
| **`mpp+mpp`（硬解+硬编）** | **27.1 fps** | **6.51 s** | **43 %** | **15.80 ms** | **36 MB** |
| `sw+mpp`（软解+硬编） | 26.7 fps | 22.53 s | 148 % | 55.63 ms | 96 MB |
| `sw+x264`（软解+软编） | **19.3 fps ✗** | 77.30 s | 377 % | 194.71 ms | 198 MB |

结论：

- **1080p 下软件编码根本跑不满实时**（19.3 fps < 30 fps），且要吃掉 **3.8 个核**；
  换成硬解+硬编后是 **27.1 fps、只占单核 43%**，CPU 降到 **1/11.9（省 92%）**。
- 720p 下软编勉强能跑（248% ≈ 2.5 个核），全硬件方案降到 **1/6.4（省 84%）**。
- 软解这一项本身就占大头：`sw+mpp` 与 `mpp+mpp` 的差值就是它（1080p 约 40 ms/帧）。
  **所以只做硬编还不够，必须同时打开硬解。**
- 内存从 198 MB 降到 36 MB，对 4 GB 的板子是实打实的余量。

### 4.3 端到端推流链路（RTSP → 硬解 → 硬编 → RTSP）

```
源: rtsp://127.0.0.1:8554/src   (1280x720@30 H.264)
    ↓  h264 (h264_rkmpp)         <- MPP 硬解，输出 nv12
    ↓  h264 (h264_rkmpp)         <- MPP 硬编（VEPU2），nv12 零拷贝直通
出: rtsp://127.0.0.1:8554/cam1  (H.264 Main 1280x720@30, CBR 2500k)
```

读回校验 20.13 s：**594 帧（≈29.5 fps，源 30 fps）**、
**转码进程仅占单核 34%**（6 核机器 ≈ 5.6% 总占用）、**解码错误 0**。

---

## 五、硬编转码推流脚本用法

`scripts/hw-encode-pipeline.sh` 是实际干活的脚本，已部署到板子 `/root/`。

```bash
./hw-encode-pipeline.sh info        # 内核/MPP/硬编硬解/摄像头/温度 一览
./hw-encode-pipeline.sh cam         # 列出摄像头与支持的分辨率、像素格式
./hw-encode-pipeline.sh test        # 1080p 合成源硬编自检
./hw-encode-pipeline.sh bench       # 跑四模式 CPU 对比基准
./hw-encode-pipeline.sh serve <输入> [名称] [码率k]   # 推到本机 MediaMTX
./hw-encode-pipeline.sh rtmp  <输入> <rtmp地址> [码率k]
./hw-encode-pipeline.sh rtsp  <输入> <rtsp地址> [码率k]
./hw-encode-pipeline.sh file  <输入> <输出.h264> [码率k]
```

输入可以是 USB 摄像头 `/dev/video1`、网络摄像头 `rtsp://user:pass@ip:554/...`、或本地文件。
脚本会**自动探测**输入编码格式并选择对应的 MPP 硬件解码器（`h264_rkmpp` / `hevc_rkmpp` / …），
选不到才回退软解。

常用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `BR` | `4000` | 目标码率 kbps |
| `GOP` | `60` | 关键帧间隔（帧），直播一般取 2 秒 |
| `RCMODE` | `CBR` | `VBR` / `CBR` / `CQP` / `AVBR` |
| `PROFILE` | `77` | `baseline=66` / `main=77` / `high=100` |
| `SCALE` | 空 | 输出缩放，如 `1280x720`（转码同时降分辨率） |
| `WITH_AUDIO` | `0` | 置 1 则保留音频并转 AAC |
| `RTSP_IN` | `tcp` | 改 `udp` 可再省一点 CPU（丢包风险） |
| `FPS` | `30` | 摄像头采集帧率 |

典型用法：

```bash
# 把网络摄像机转码后挂到本机 MediaMTX，再对外分发
./hw-encode-pipeline.sh serve 'rtsp://admin:pass@192.168.1.64:554/Streaming/Channels/101' cam1 4000
# 本地观看
ffplay -fflags nobuffer rtsp://<板子IP>:8554/cam1

# 一路主码流(1080p)+一路降码率(720p)，CPU 各占单核约 40%
./hw-encode-pipeline.sh serve 'rtsp://.../101' main   6000
SCALE=1280x720 BR=1500 ./hw-encode-pipeline.sh serve 'rtsp://.../101' sub 1500

# 推到直播平台
./hw-encode-pipeline.sh rtmp /dev/video1 rtmp://live-push.example.com/live/abc 6000
```

参数上的注意点（都是踩过的坑）：

- **`h264_rkmpp` 没有 `-zerolatency` 选项**，低延迟靠 `-bf 0` + 短 `GOP` 实现。
- **不要加 `-vf format=nv12`**：MPP 解码器直接输出 `nv12`，硬编也收 `nv12`，
  加了这个滤镜反而插入一次多余的格式转换。让 ffmpeg 自己协商即可零拷贝。
- 强制指定输入解码器要用 `-c:v h264_rkmpp` **放在 `-i` 前面**，
  放在后面只是指定输出编码器。

### 测试用的本机 MediaMTX

板子上已装好 MediaMTX v1.21.2，作为 `mediamtx.service` 常驻（RTSP `:8554` / RTMP `:1935`）。

```bash
systemctl status mediamtx
```

配置文件里**必须有 `paths: all_others:`**，否则发布任何路径都会报
`Server returned 400 Bad Request`，日志里写的是 `path 'xxx' is not configured`。

---

## 六、风险提示（重要）

1. **设备只有 eMMC、无 SD 卡时，新内核起不来就只能重刷。** 建议先准备好救援手段
   （串口 `ttyS2@1500000` + Maskrom，或 TF 卡启动盘）。
2. U-Boot 是 `2020.10-armbian`，**没有编译 `bootcount`/`bootlimit`**，所以
   **没有"启动失败自动回退"**，回滚必须手动。
3. `develop-6.1` 是 Rockchip 给自家产品线用的分支，直接配 Armbian 用户态属于
   «厂内核 + 发行版» 的混搭。本机实测通过了，但换板子/换系统不保证。
4. 最容易出问题的地方是 **PMIC / 以太网 PHY / 电源域 / 时钟**。如果新内核起来但
   网卡不工作，优先检查 `dmesg | grep -iE 'gmac|stmmac|dwmmc|sdhci|vcc'`。
5. 编译产物只含内核，不含 U-Boot / 分区表，**不会破坏 bootloader**。

---

## 七、已知的小问题

- 杀掉 `ffmpeg`（比如 Ctrl-C）时，MPP 用户态库会打印几行
  `mpp_mem_pool: mpp_mem_pool_put invalid mem pool ptr ...`，
  这是**强制终止时的清理噪音，不影响已经编好的流**，正常结束不会出现。
- 本仓库默认用 `keep_minimal=true` 编译，关掉了 ISP / AIISP / VPSS / 声卡等无关子系统。
  需要时用 `keep_minimal=false` 重编一次即可拿回完整功能。
