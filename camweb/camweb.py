#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RK3399 摄像头采集 / 编解码 网页测试服务（纯标准库，无需 pip 安装）。

设计要点
--------
* 四种模式：
    passthrough  —— 摄像头本身输出 H.264，直接 -c copy 转发到 MediaMTX，CPU 几乎为零
    hwenc        —— 摄像头 MJPEG -> ffmpeg h264_rkmpp 硬件编码 -> MediaMTX（核心「硬编码」验证）
    mjpeg        —— 摄像头 MJPEG 原样经本地 multipart 直出到浏览器（零编码、最低延迟，看原始画质）
    testpat      —— 无摄像头也能跑：lavfi 测试图 -> h264_rkmpp -> MediaMTX（用于验证网页/链路本身）
* 浏览器播放：
    passthrough / hwenc / testpat 走 MediaMTX 的 HLS，由本服务做同源代理（避开 CORS），
    前端用**本地托管**的 hls.js 播放（不依赖外网 CDN，离线环境也能出画面）
    mjpeg 走本服务的 /video/mjpeg（multipart/x-mixed-replace），前端用 <img> 显示
* 摄像头自动探测：扫描 /dev/video*，挑出支持 MJPG/H264 的 UVC 节点，
  不再硬编码 /dev/video1（摄像头重新插拔后节点号会变）
* 统计：从 ffmpeg stderr 解析 fps / bitrate，从 /proc 解析 ffmpeg 进程 CPU 占用
* 启动快速失败：ffmpeg 若立刻退出（设备不存在/格式不支持），把退出原因回传给前端显示

依赖：ffmpeg(带 h264_rkmpp) + v4l2-ctl + MediaMTX（均在板端已就绪）
"""
import os
import re
import glob
import json
import time
import threading
import subprocess
import collections
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
import urllib.request

# ----------------------------- 配置 -----------------------------
FFMPEG = "/usr/local/ffmpeg-rkmpp/bin/ffmpeg"
CAM_DEV_HINT = "/dev/video1"        # 仅作为提示；实际设备由 detect_camera() 自动探测
CAM_DEV = CAM_DEV_HINT              # 兼容旧引用
MTX_RTSP = "rtsp://127.0.0.1:8554"
STREAM_PATH = "cam"
MTX_HLS = "http://127.0.0.1:8888"   # MediaMTX 的 HLS 监听（hlsAddress 默认 :8888）
PORT = 8080
HERE = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(HERE, "static")
NATIVE_FORMATS = ("MJPG", "MJPEG", "H264")

# ----------------------------- 全局状态 -----------------------------
state = {
    "proc": None,
    "mode": None,
    "params": {},
    "started": 0,
    "fps": None,
    "kbps": None,
    "cpu": None,
    "real_fps": None,
    "log": [],
    "error": None,
    "mjpeg_buf": collections.deque(maxlen=1),  # 仅保留最新一帧
    "mjpeg_clients": 0,
}
state["mjpeg_cond"] = threading.Condition()
# RLock（可重入）：start_pipeline 会在持锁时调用 stop_pipeline，
# 用普通 Lock 会自死锁 —— 表现为「已有流在跑时点开始，整个服务永久卡死」
LOCK = threading.RLock()
CAMERA_CACHE = {"ts": 0, "data": None, "ttl": 0}


# ----------------------------- 摄像头探测 -----------------------------
def _parse_formats(out):
    """解析 v4l2-ctl --list-formats-ext 的输出。"""
    formats = []
    cur = None
    size = None
    for line in out.splitlines():
        m = re.match(r"\s*\[(\d+)\]:\s*'([^']+)'\s*\(([^)]*)\)", line)
        if m:
            cur = {"format": m.group(2), "desc": m.group(3), "sizes": []}
            formats.append(cur)
            size = None
            continue
        m = re.match(r"\s*Size:\s*Discrete\s*(\d+)x(\d+)", line)
        if m and cur:
            size = {"w": int(m.group(1)), "h": int(m.group(2)), "fps": []}
            cur["sizes"].append(size)
            continue
        m = re.match(r"\s*Interval:\s*Discrete\s*([\d.]+)s\s*\(([\d.]+)\s*fps\)", line)
        if m and size:
            size["fps"].append(float(m.group(2)))
    return formats


def _v4l2_formats(dev):
    try:
        out = subprocess.run(
            ["v4l2-ctl", "-d", dev, "--list-formats-ext"],
            capture_output=True, text=True, timeout=10,
        ).stdout
    except Exception:
        return None
    return _parse_formats(out)


def _video_nodes():
    """按编号排序的 /dev/video* 列表（排除 rga/isp 之类无 MJPG/H264 的节点在后续过滤）。"""
    def key(p):
        m = re.search(r"(\d+)$", p)
        return int(m.group(1)) if m else 0
    return sorted(glob.glob("/dev/video*"), key=key)


def detect_camera(force=False):
    """扫描所有 /dev/video*，返回第一个支持 MJPG/H264 的采集节点。

    返回值: {"device": "/dev/videoN"|None, "available": bool, "formats": [...]}
    缓存策略：找到 -> 缓存 30s；没找到 -> 只缓存 3s（便于插回摄像头后快速恢复）
    """
    now = time.time()
    if not force and CAMERA_CACHE["data"] is not None and now - CAMERA_CACHE["ts"] < CAMERA_CACHE["ttl"]:
        return CAMERA_CACHE["data"]

    found = None
    for dev in _video_nodes():
        fmts = _v4l2_formats(dev)
        if not fmts:
            continue
        if any(f["format"] in NATIVE_FORMATS for f in fmts):
            found = {
                "device": dev,
                "available": True,
                "formats": fmts,
                "formats_list": [f["format"] for f in fmts],
                "nodes": _video_nodes(),
            }
            break

    if found is None:
        found = {
            "device": None,
            "available": False,
            "formats": [],
            "formats_list": [],
            "nodes": _video_nodes(),
            "hint": CAM_DEV_HINT,
        }

    CAMERA_CACHE["data"] = found
    CAMERA_CACHE["ts"] = now
    CAMERA_CACHE["ttl"] = 30 if found["available"] else 3
    return found


def camera_watcher():
    """后台刷新摄像头状态，使 /api/status 不必各自去探测。"""
    while True:
        try:
            with LOCK:
                busy = bool(state["proc"] and state["proc"].poll() is None)
            # 流正在跑时不要去枚举设备（UVC 枚举会和采集抢占），缓存 30s 足够
            if not busy:
                detect_camera()
        except Exception:
            pass
        time.sleep(3)


def default_native(formats):
    """返回摄像头原生最优能力（取 MJPG 或 H264 的最高分辨率 30fps）。"""
    best = None
    for f in formats:
        if f["format"] not in NATIVE_FORMATS:
            continue
        for s in f["sizes"]:
            fps = max(s["fps"]) if s["fps"] else 30
            score = s["w"] * s["h"]
            if best is None or score > best["score"]:
                best = {"format": f["format"], "w": s["w"], "h": s["h"],
                        "fps": int(fps), "score": score}
    return best or {"format": "MJPG", "w": 1920, "h": 1080, "fps": 30, "score": 0}


# ----------------------------- 管线构造 -----------------------------
HDR = ["-hide_banner", "-loglevel", "info",
       "-fflags", "nobuffer", "-flags", "low_delay", "-fflags", "+genpts"]

# 硬编时可选的解码路径（实测 1920x1080@30 真实帧率，见 README）
HWENC_DECODES = ("sw", "zero", "hw")


def _in_opts(fmt, w, h, fps, dev):
    # -input_format 是输入选项，必须放在 -i 之前，否则 ffmpeg 会忽略它
    return ["-f", "v4l2", "-thread_queue_size", "512",
            "-input_format", fmt,
            "-video_size", f"{w}x{h}", "-framerate", str(fps), "-i", dev]


def _enc_opts(br, gop, pix_fmt=True):
    o = ["-c:v", "h264_rkmpp", "-rc_mode", "CBR",
         "-b:v", f"{br}k", "-maxrate", f"{br}k", "-bufsize", f"{br*2}k",
         "-g", str(gop), "-bf", "0"]
    if pix_fmt:
        o += ["-pix_fmt", "nv12"]
    return o


def build_cmd(mode, p, variant=None):
    w, h, fps = int(p["width"]), int(p["height"]), int(p["fps"])
    dev = p.get("device", CAM_DEV_HINT)
    br = int(p.get("bitrate", 4000))
    gop = int(p.get("gop", 30))

    if mode == "testpat":
        # 无摄像头：lavfi 测试图 -> VPU 硬编 -> MediaMTX（用于验证网页播放链路本身）
        return [FFMPEG, "-hide_banner", "-loglevel", "info", "-re",
                "-f", "lavfi", "-i", f"testsrc2=size={w}x{h}:rate={fps}",
                *_enc_opts(br, gop),
                "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]

    if mode == "hwenc":
        if variant == "zero":
            # 零拷贝：MJPEG 由 VPU 解码，帧留在 DMA 缓冲直接喂 h264_rkmpp
            return [FFMPEG, *HDR,
                    "-hwaccel", "rkmpp", "-hwaccel_output_format", "drm_prime",
                    *_in_opts("mjpeg", w, h, fps, dev),
                    *_enc_opts(br, gop, pix_fmt=False),
                    "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]
        if variant == "hw":
            # VPU 硬解 MJPEG（mjpeg_rkmpp）后再硬编
            return [FFMPEG, *HDR, "-c:v", "mjpeg_rkmpp",
                    *_in_opts("mjpeg", w, h, fps, dev),
                    *_enc_opts(br, gop),
                    "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]
        # 默认 sw：CPU 软解 MJPEG + VPU 硬编。
        # CPU 调频修复后这是最快路径（1920x1080@30 可跑满 30fps），
        # 因为 RK3399 的 MJPEG 硬解本身只有 ~17-20fps。
        return [FFMPEG, *HDR,
                *_in_opts("mjpeg", w, h, fps, dev),
                *_enc_opts(br, gop),
                "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]

    if mode == "passthrough":
        # 摄像头自带 H.264，仅转发；mp4toannexb 确保 SPS/PPS 内联供 RTSP/HLS 切片
        return [FFMPEG, *HDR, *_in_opts("h264", w, h, fps, dev),
                "-bsf:v", "h264_mp4toannexb", "-c", "copy",
                "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]

    if mode == "mjpeg":
        # 直接 pipe MJPEG 到本服务，由 /video/mjpeg 以 multipart 推给浏览器
        return [FFMPEG, *HDR, *_in_opts("mjpeg", w, h, fps, dev),
                "-c", "copy", "-f", "mjpeg", "-"]

    raise ValueError("未知模式: %s" % mode)


def _clean(lines):
    """过滤 MPP 的底层噪声（mpp[...]...），保留 ffmpeg 自己的信息行。

    若过滤后为空则原样返回，避免把失败原因也一起吞掉。
    """
    out = [l for l in lines if not l.lstrip().startswith("mpp[")]
    return out if out else list(lines)


def _kill_proc(proc, timeout=5):
    """在锁外做耗时操作：先 SIGTERM，超时再 SIGKILL。"""
    if not proc or proc.poll() is not None:
        return
    try:
        proc.terminate()
    except Exception:
        pass
    try:
        proc.wait(timeout=timeout)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=2)
        except Exception:
            pass


def stop_pipeline():
    """清空状态（持锁时间极短），再把耗时的进程回收放到锁外。"""
    with LOCK:
        proc = state["proc"]
        state["proc"] = None
        state["mode"] = None
        state["params"] = {}
        state["fps"] = None
        state["kbps"] = None
        state["cpu"] = None
        state["real_fps"] = None
        state["log"] = []
        state["error"] = None
        state["mjpeg_buf"].clear()
    _kill_proc(proc)


def start_pipeline(mode, params):
    # 先停掉正在跑的流：必须在锁**外**调用，否则 start 持有 LOCK 再进 stop 会自死锁
    with LOCK:
        running = state["proc"]
    if running is not None:
        stop_pipeline()

    need_cam = (mode != "testpat")
    cam = detect_camera()
    device = params.get("device") or cam.get("device")

    if need_cam:
        if not device:
            return False, "未检测到 USB 摄像头。请插好摄像头后点「重新检测」，或改用「测试图」模式验证网页。"
        if not os.path.exists(device):
            detect_camera(force=True)
            return False, "摄像头节点 %s 不存在（可能已掉线）。请重新插拔 USB 摄像头。" % device

    native = default_native(cam.get("formats", []))
    p = {
        "device": device if need_cam else "-",
        "width": int(params.get("width") or native["w"]),
        "height": int(params.get("height") or native["h"]),
        "fps": int(params.get("fps") or native["fps"]),
        "bitrate": int(params.get("bitrate") or 4000),
        "gop": int(params.get("gop") or 30),
    }
    try:
        cmd = build_cmd(mode, p)
    except ValueError as e:
        return False, str(e)

    # hwenc 的解码路径可选（sw 软解 / zero 零拷贝 / hw 硬解）；
    # 首选失败则自动依次回退到其它路径，保证始终可用
    if mode == "hwenc":
        dec = params.get("decode") or "sw"
        if dec not in HWENC_DECODES:
            dec = "sw"
        variants = [dec] + [d for d in ("sw", "zero", "hw") if d != dec]
    else:
        variants = [None]
    mjpeg_mode = (mode == "mjpeg")

    last_msg = "启动失败"
    for variant in variants:
        try:
            cmd = build_cmd(mode, p, variant)
        except ValueError as e:
            return False, str(e)

        try:
            proc = subprocess.Popen(
                cmd, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE if mjpeg_mode else subprocess.DEVNULL,
                stderr=subprocess.PIPE, bufsize=0,
            )
        except Exception as e:  # noqa
            return False, "启动 ffmpeg 失败: %s" % e

        if variant:
            p["decode"] = variant
        with LOCK:
            state["proc"] = proc
            state["mode"] = mode
            state["params"] = dict(p)
            state["started"] = time.time()
            state["log"] = []
            state["error"] = None
            state["fps"] = None
            state["real_fps"] = None
            state["kbps"] = None
            state["cpu"] = None

        stats_th = threading.Thread(target=stats_reader, args=(proc,), daemon=True)
        stats_th.start()
        if mjpeg_mode:
            threading.Thread(target=mjpeg_reader, args=(proc,), daemon=True).start()
        threading.Thread(target=cpu_sampler, args=(proc,), daemon=True).start()

        # ---- 快速失败探测：ffmpeg 若立刻退出（设备被占用/格式不支持/参数错），
        #      把 stderr 尾部原因带回前端，而不是让页面以为「已启动」。
        time.sleep(1.0)
        if proc.poll() is None:
            return True, "ok"

        stats_th.join(timeout=2.0)
        with LOCK:
            tail = list(state["log"][-6:])
            state["proc"] = None
            state["mode"] = None
            state["error"] = "ffmpeg 退出码 %s" % proc.returncode
            state["log"] = tail
        last_msg = "ffmpeg 启动即退出（退出码 %s）：%s" % (
            proc.returncode, " | ".join(_clean(tail)[-3:]) or "无输出")

    return False, last_msg


# ----------------------------- 后台读取线程 -----------------------------
def stats_reader(proc):
    # ffmpeg 进度行用 \r 刷新（无 \n），故按 \r/\n 切分；跨读保留半行
    leftover = b""
    while True:
        chunk = proc.stderr.read(4096)
        if not chunk:
            break
        data = leftover + chunk.replace(b"\r", b"\n")
        parts = data.split(b"\n")
        leftover = parts.pop()
        for raw in parts:
            line = raw.decode("utf-8", "ignore").strip()
            if not line:
                continue
            fm = re.search(r"fps=\s*([\d.]+)", line)
            brm = re.search(r"bitrate=\s*([\d.]+)\s*kbits/s", line)
            # ffmpeg 的 fps= 会因补帧(vsync dup)而虚高：必须减去 dup 才是真实处理帧率。
            # 例：1080p MJPEG->H264 硬解路径显示 fps=27，但 dup=247，真实只有 ~17fps。
            fr = re.search(r"frame=\s*(\d+)", line)
            du = re.search(r"dup=\s*(\d+)", line)
            tm = re.search(r"time=(\d+):(\d+):([\d.]+)", line)
            real = None
            if fr and tm:
                secs = int(tm.group(1)) * 3600 + int(tm.group(2)) * 60 + float(tm.group(3))
                if secs > 0:
                    real = round((int(fr.group(1)) - (int(du.group(1)) if du else 0)) / secs, 1)
            with LOCK:
                if fm:
                    state["fps"] = float(fm.group(1))
                if brm:
                    state["kbps"] = float(brm.group(1))
                if real is not None:
                    state["real_fps"] = real
                state["log"].append(line)
                if len(state["log"]) > 200:
                    state["log"].pop(0)
    if proc.poll() is not None and proc.returncode != 0:
        with LOCK:
            if state["proc"] is proc:
                state["error"] = "ffmpeg 退出码 %d" % proc.returncode


def mjpeg_reader(proc):
    """从 ffmpeg -f mjpeg - 的 stdout 切出完整 JPEG 帧，存入环形缓冲。"""
    buf = b""
    while True:
        chunk = proc.stdout.read(65536)
        if not chunk:
            break
        buf += chunk
        while True:
            s = buf.find(b"\xff\xd8")          # SOI
            if s < 0:
                buf = buf[-8192:]              # 没找到头，保留尾部防止分裂
                break
            e = buf.find(b"\xff\xd9", s + 2)   # EOI
            if e < 0:
                buf = buf[s:]                  # 等更多数据凑齐一帧
                break
            frame = buf[s:e + 2]
            buf = buf[e + 2:]
            with state["mjpeg_cond"]:
                state["mjpeg_buf"].append(frame)
                state["mjpeg_cond"].notify_all()


def cpu_sampler(proc):
    """每 1s 采样一次 ffmpeg 进程 CPU 占用（单核百分比）。"""
    clk = os.sysconf("SC_CLK_TCK") or 100
    last_ut = last_st = last_wall = None
    while proc.poll() is None:
        try:
            with open("/proc/%d/stat" % proc.pid) as f:
                f1 = f.read().split()
            ut = int(f1[13])
            st = int(f1[14])
            wall = time.time()
            if last_wall is not None:
                dcpu = (ut - last_ut) + (st - last_st)
                dwall = wall - last_wall
                if dwall > 0:
                    pct = dcpu / clk / dwall * 100.0
                    with LOCK:
                        state["cpu"] = round(pct, 1)
            last_ut, last_st, last_wall = ut, st, wall
        except Exception:
            break
        time.sleep(1)


# ----------------------------- HLS 代理 -----------------------------
def proxy_hls(path, handler):
    url = MTX_HLS.rstrip("/") + "/" + path
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "camweb"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            ctype = resp.headers.get("Content-Type", "application/octet-stream")
            data = resp.read()
        handler.send_response(200)
        handler.send_header("Content-Type", ctype)
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)
    except Exception as e:  # noqa
        # send_error 的 message 会写进 HTTP 状态行，只允许 latin-1，
        # 中文会抛 UnicodeEncodeError 并丢掉连接 —— 所以这里一律用 ASCII
        sys.stderr.write("HLS proxy failed: %r\n" % (e,))
        handler.send_error(502, "HLS proxy failed")


MIME = {
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".html": "text/html; charset=utf-8",
    ".map": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".ico": "image/x-icon",
}


# ----------------------------- HTTP 处理 -----------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "camweb/1.1"

    def _send_json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8", "ignore") or "{}")
        except Exception:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/" or path == "/index.html":
            self._serve_file("index.html", "text/html; charset=utf-8")
        elif path.startswith("/static/"):
            self._serve_static(path[len("/static/"):])
        elif path == "/api/camera":
            cam = detect_camera(force=("force" in parse_qs(parsed.query)))
            self._send_json(cam)
        elif path == "/api/status":
            self._send_json(self._status())
        elif path == "/video/mjpeg":
            self._serve_mjpeg()
        elif path.startswith("/hls/"):
            # 用 self.path（含查询串）：LL-HLS 的阻塞式重载靠 ?_HLS_msn=/_HLS_part= 参数，
            # 若丢掉查询串，hls.js 的阻塞请求会立即返回，导致疯狂重载
            proxy_hls(self.path[len("/hls/"):], self)
        elif path == "/healthz":
            self._send_json({"ok": True})
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/api/start":
            body = self._read_body()
            mode = body.get("mode")
            if mode not in ("passthrough", "hwenc", "mjpeg", "testpat"):
                return self._send_json({"ok": False, "msg": "mode 非法"}, 400)
            ok, msg = start_pipeline(mode, body)
            return self._send_json({"ok": ok, "msg": msg, "status": self._status()})
        elif path == "/api/stop":
            stop_pipeline()
            return self._send_json({"ok": True, "status": self._status()})
        else:
            self.send_error(404)

    def _status(self):
        cam = CAMERA_CACHE["data"] or {"available": False, "device": None}
        with LOCK:
            return {
                "running": bool(state["proc"] and state["proc"].poll() is None),
                "mode": state["mode"],
                "params": state["params"],
                "started": state["started"],
                "uptime": round(time.time() - state["started"], 1) if state["started"] else 0,
                "fps": state["fps"],
                "real_fps": state["real_fps"],
                "kbps": state["kbps"],
                "cpu": state["cpu"],
                "error": state["error"],
                "camera": {"available": cam.get("available", False), "device": cam.get("device")},
                "hls": f"{MTX_HLS}/{STREAM_PATH}/index.m3u8",
                "rtsp": f"{MTX_RTSP}/{STREAM_PATH}",
                "log_tail": _clean(state["log"])[-12:],
            }

    def _serve_file(self, name, ctype):
        fp = os.path.join(HERE, name)
        if not os.path.isfile(fp):
            self.send_error(404, "file not found: %s" % name)
            return
        with open(fp, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(data)

    def _serve_static(self, rel):
        rel = rel.split("?")[0].lstrip("/")
        if ".." in rel:
            self.send_error(403)
            return
        fp = os.path.join(STATIC_DIR, rel)
        if not os.path.isfile(fp):
            self.send_error(404, "static not found: %s" % rel)
            return
        ext = os.path.splitext(fp)[1].lower()
        with open(fp, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", MIME.get(ext, "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def _serve_mjpeg(self):
        with LOCK:
            if state["mode"] != "mjpeg" or not (state["proc"] and state["proc"].poll() is None):
                self.send_error(409, "not running in mjpeg mode")
                return
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        boundary = b"\r\n--frame\r\n"
        try:
            self.wfile.write(b"--frame\r\n")
            while True:
                with LOCK:
                    alive = (state["mode"] == "mjpeg" and state["proc"] is not None
                             and state["proc"].poll() is None)
                if not alive:
                    break   # 流已停止 -> 主动断开，避免连接线程泄漏
                with state["mjpeg_cond"]:
                    frame = state["mjpeg_buf"][-1] if state["mjpeg_buf"] else None
                    if frame is None:
                        state["mjpeg_cond"].wait(timeout=0.15)
                        continue
                self.wfile.write(
                    b"Content-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n" % len(frame)
                    + frame + boundary
                )
        except Exception:
            pass

    def log_message(self, *args):
        pass  # 静默访问日志


class CamwebServer(ThreadingHTTPServer):
    daemon_threads = True          # 不因残留连接阻塞退出
    allow_reuse_address = True


def main():
    detect_camera(force=True)  # 预热缓存
    threading.Thread(target=camera_watcher, daemon=True).start()
    srv = CamwebServer(("0.0.0.0", PORT), Handler)
    cam = CAMERA_CACHE["data"] or {}
    print("camweb 已启动: http://0.0.0.0:%d  摄像头=%s" % (
        PORT, cam.get("device") or "未检测到"))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        stop_pipeline()
        srv.shutdown()


if __name__ == "__main__":
    main()
