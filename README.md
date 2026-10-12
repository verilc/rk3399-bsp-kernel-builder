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
└── scripts/rollback.sh                  # 设备侧回滚脚本
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

### 6. 回滚

```bash
bash rollback.sh --list     # 看有哪些时间点
bash rollback.sh            # 回滚到最近一次部署前
```

---

## 四、风险提示（重要）

1. **设备只有 eMMC、无 SD 卡时，新内核起不来就只能重刷。** 建议先准备好救援手段
   （串口 `ttyS2@1500000` + Maskrom，或 TF 卡启动盘）。
2. U-Boot 是 `2020.10-armbian`，**没有编译 `bootcount`/`bootlimit`**，所以
   **没有"启动失败自动回退"**，回滚必须手动。
3. `develop-6.1` 是 Rockchip 给自家产品线用的分支，直接配 Armbian 用户态属于
   «厂内核 + 发行版» 的混搭，第一次不一定能完美点亮。工作流已尽量把网络、存储、
   文件系统选项补齐来降低风险，但仍需实测。
4. 最容易出问题的地方是 **PMIC / 以太网 PHY / 电源域 / 时钟**。如果新内核起来但
   网卡不工作，优先检查 `dmesg | grep -iE 'gmac|stmmac|dwmmc|sdhci|vcc'`。
5. 编译产物只含内核，不含 U-Boot / 分区表，**不会破坏 bootloader**。

---

## 五、下一步（内核跑通之后）

1. 编译 `librockchip_mpp` 用户态库
2. 用 `mpi_enc_test` 验证 H.264 硬编码确实走 VEPU2
3. 搭实时转码推流链路：`USB 摄像头 → V4L2 → MPP 硬编 H.264 → RTMP/RTSP`
   - GStreamer：`v4l2src ! ... ! mpph264enc ! flvmux ! rtmpsink`
   - 或 ffmpeg（rkmpp 版）：`-c:v h264_rkmpp`
4. 对比硬编/软编的 CPU 占用与延迟
