#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
RK3399 摄像头采集 / 编解码 网页测试服务（纯标准库，无需 pip 安装）。

设计要点
--------
* 三种模式：
    passthrough  —— 摄像头本身输出 H.264，直接 -c copy 转发到 MediaMTX，CPU 几乎为零
    hwenc        —— 摄像头 MJPEG -> ffmpeg h264_rkmpp 硬件编码 -> MediaMTX（核心「硬编码」验证）
    mjpeg        —— 摄像头 MJPEG 原样经本地 multipart 直出到浏览器（零编码、最低延迟，看原始画质）
* 浏览器播放：
    passthrough / hwenc 走 MediaMTX 的 HLS，由本服务做同源代理（避开 CORS），前端用 hls.js 播放
    mjpeg 走本服务的 /video/mjpeg（multipart/x-mixed-replace），前端用 <img> 显示
* 统计：从 ffmpeg stderr 解析 fps / bitrate，从 /proc 解析 ffmpeg 进程 CPU 占用

依赖：ffmpeg(带 h264_rkmpp) + v4l2-ctl + MediaMTX（均在板端已就绪）
"""
import os
import re
import sys
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
CAM_DEV = "/dev/video1"          # H264/MJPG 双格式节点（probed 时自动兜底）
MTX_RTSP = "rtsp://127.0.0.1:8554"
STREAM_PATH = "cam"
MTX_HLS = "http://127.0.0.1:8888"   # MediaMTX 的 HLS 监听（hlsAddress 默认 :8888）
PORT = 8080
HERE = os.path.dirname(os.path.abspath(__file__))

# ----------------------------- 全局状态 -----------------------------
state = {
    "proc": None,
    "mode": None,
    "params": {},
    "started": 0,
    "fps": None,
    "kbps": None,
    "cpu": None,
    "log": [],
    "error": None,
    "mjpeg_buf": collections.deque(maxlen=1),  # 仅保留最新一帧
    "mjpeg_clients": 0,
}
state["mjpeg_cond"] = threading.Condition()
LOCK = threading.Lock()
CAMERA_CACHE = {"ts": 0, "data": None}


# ----------------------------- 摄像头探测 -----------------------------
def probe_camera(dev=CAM_DEV, force=False):
    now = time.time()
    if not force and CAMERA_CACHE["data"] and now - CAMERA_CACHE["ts"] < 30:
        return CAMERA_CACHE["data"]
    try:
        out = subprocess.run(
            ["v4l2-ctl", "-d", dev, "--list-formats-ext"],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except Exception as e:  # noqa
        return {"device": dev, "error": str(e), "formats": []}

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

    # 自动挑一个既能当默认输入的节点：优先有 MJPG 或 H264 的
    data = {"device": dev, "formats": formats, "formats_list": [f["format"] for f in formats]}
    CAMERA_CACHE["data"] = data
    CAMERA_CACHE["ts"] = now
    return data


def default_native(formats):
    """返回摄像头原生最优能力（取 MJPG 或 H264 的最高分辨率 30fps）。"""
    best = None
    for f in formats:
        if f["format"] not in ("MJPG", "H264", "MJPEG"):
            continue
        for s in f["sizes"]:
            fps = max(s["fps"]) if s["fps"] else 30
            score = s["w"] * s["h"]
            if best is None or score > best["score"]:
                best = {"format": f["format"], "w": s["w"], "h": s["h"],
                        "fps": int(fps), "score": score}
    return best or {"format": "MJPG", "w": 1920, "h": 1080, "fps": 30, "score": 0}


# ----------------------------- 管线构造 -----------------------------
def build_cmd(mode, p):
    w, h, fps = int(p["width"]), int(p["height"]), int(p["fps"])
    dev = p.get("device", CAM_DEV)
    # 注意：-input_format 是输入选项，必须放在 -i 之前，否则 ffmpeg 会忽略它
    # （之前 passthrough 因此退回 MJPG 默认格式而推流失败）
    fmt = "h264" if mode == "passthrough" else "mjpeg"
    in_prefix = ["-hide_banner", "-loglevel", "info", "-fflags", "nobuffer",
                 "-flags", "low_delay", "-fflags", "+genpts",
                 "-f", "v4l2", "-thread_queue_size", "512",
                 "-input_format", fmt,
                 "-video_size", f"{w}x{h}", "-framerate", str(fps), "-i", dev]
    if mode == "passthrough":
        # 摄像头自带 H.264，仅转发；mp4toannexb 确保 SPS/PPS 内联供 RTSP/HLS 切片
        return [FFMPEG, *in_prefix, "-bsf:v", "h264_mp4toannexb",
                "-c", "copy", "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]
    if mode == "hwenc":
        br = int(p.get("bitrate", 4000))
        gop = int(p.get("gop", 30))
        return [FFMPEG, *in_prefix,
                "-c:v", "h264_rkmpp", "-rc_mode", "CBR",
                "-b:v", f"{br}k", "-maxrate", f"{br}k", "-bufsize", f"{br*2}k",
                "-g", str(gop), "-bf", "0", "-pix_fmt", "nv12",
                "-f", "rtsp", f"{MTX_RTSP}/{STREAM_PATH}"]
    if mode == "mjpeg":
        # 直接 pipe MJPEG 到本服务，由 /video/mjpeg 以 multipart 推给浏览器
        return [FFMPEG, *in_prefix, "-c", "copy", "-f", "mjpeg", "-"]
    raise ValueError("未知模式: %s" % mode)


def stop_pipeline():
    with LOCK:
        proc = state["proc"]
        if proc and proc.poll() is None:
            try:
                proc.terminate()
            except Exception:
                pass
        # 给子进程一点时间退出
        if proc:
            try:
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        state["proc"] = None
        state["mode"] = None
        state["params"] = {}
        state["fps"] = None
        state["kbps"] = None
        state["cpu"] = None
        state["log"] = []
        state["error"] = None
        state["mjpeg_buf"].clear()


def start_pipeline(mode, params):
    with LOCK:
        if state["proc"] and state["proc"].poll() is None:
            stop_pipeline()

    cam = probe_camera(params.get("device", CAM_DEV))
    native = default_native(cam.get("formats", []))
    p = {
        "device": params.get("device", CAM_DEV),
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

    mjpeg_mode = (mode == "mjpeg")
    stdin = subprocess.DEVNULL
    stdout = subprocess.PIPE if mjpeg_mode else subprocess.DEVNULL
    stderr = subprocess.PIPE

    try:
        proc = subprocess.Popen(
            cmd, stdin=stdin, stdout=stdout, stderr=stderr,
            bufsize=0,
        )
    except Exception as e:  # noqa
        return False, "启动 ffmpeg 失败: %s" % e

    with LOCK:
        state["proc"] = proc
        state["mode"] = mode
        state["params"] = p
        state["started"] = time.time()
        state["log"] = []
        state["error"] = None
        state["fps"] = None
        state["kbps"] = None
        state["cpu"] = None

    threading.Thread(target=stats_reader, args=(proc,), daemon=True).start()
    if mjpeg_mode:
        threading.Thread(target=mjpeg_reader, args=(proc,), daemon=True).start()
    threading.Thread(target=cpu_sampler, args=(proc,), daemon=True).start()
    return True, "ok"


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
            with LOCK:
                if fm:
                    state["fps"] = float(fm.group(1))
                if brm:
                    state["kbps"] = float(brm.group(1))
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
        handler.send_error(502, "HLS 代理失败: %s" % e)


# ----------------------------- HTTP 处理 -----------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "camweb/1.0"

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
        elif path == "/api/camera":
            dev = parse_qs(parsed.query).get("dev", [CAM_DEV])[0]
            self._send_json(probe_camera(dev, force=("force" in parse_qs(parsed.query))))
        elif path == "/api/status":
            self._send_json(self._status())
        elif path == "/video/mjpeg":
            self._serve_mjpeg()
        elif path.startswith("/hls/"):
            proxy_hls(path[len("/hls/"):], self)
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
            if mode not in ("passthrough", "hwenc", "mjpeg"):
                return self._send_json({"ok": False, "msg": "mode 非法"}, 400)
            ok, msg = start_pipeline(mode, body)
            return self._send_json({"ok": ok, "msg": msg, "status": self._status()})
        elif path == "/api/stop":
            stop_pipeline()
            return self._send_json({"ok": True, "status": self._status()})
        else:
            self.send_error(404)

    def _status(self):
        with LOCK:
            return {
                "running": bool(state["proc"] and state["proc"].poll() is None),
                "mode": state["mode"],
                "params": state["params"],
                "started": state["started"],
                "uptime": round(time.time() - state["started"], 1) if state["started"] else 0,
                "fps": state["fps"],
                "kbps": state["kbps"],
                "cpu": state["cpu"],
                "error": state["error"],
                "hls": f"{MTX_HLS}/{STREAM_PATH}/index.m3u8",
                "rtsp": f"{MTX_RTSP}/{STREAM_PATH}",
                "log_tail": state["log"][-12:],
            }

    def _serve_file(self, name, ctype):
        fp = os.path.join(HERE, name)
        if not os.path.isfile(fp):
            self.send_error(404, "%s 不存在" % name)
            return
        with open(fp, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _serve_mjpeg(self):
        with LOCK:
            if state["mode"] != "mjpeg" or not (state["proc"] and state["proc"].poll() is None):
                self.send_error(409, "当前不是 mjpeg 模式或未运行")
                return
        self.send_response(200)
        self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        boundary = b"\r\n--frame\r\n"
        try:
            self.wfile.write(b"--frame\r\n")
            while True:
                with state["mjpeg_cond"]:
                    frame = None
                    if state["mjpeg_buf"]:
                        frame = state["mjpeg_buf"][-1]
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


def main():
    probe_camera()  # 预热缓存
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("camweb 已启动: http://0.0.0.0:%d  (摄像头=%s)" % (PORT, CAM_DEV))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        stop_pipeline()
        srv.shutdown()


if __name__ == "__main__":
    main()
