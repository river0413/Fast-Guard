"""手机浏览器直连的 Web 服务（无需安装 APK）。

在**同一个推理进程**里再开一个 HTTP 端口，于是同一个 ``EngineBridge`` /
``FrameHub`` 同时服务：

* ``GET /``            移动端界面（满屏 AI 推理画面 + 左上汉堡设置栏 + 右上"卸载推理"徽标）
* ``GET /stream``      MJPEG 视频流（复用 FrameHub 已编码好的 JPEG，不额外占用推理）
* ``GET /status``      引擎状态 JSON（界面据此显示连接状态）
* ``GET /bev``         最新的 BEV 画面 JPEG（可选叠加）
* ``POST /api/<cmd>``  控制指令（摄像头 / 阈值 / 推理图片大小 / BEV）

按设计要求：**不提供预处理画面，也不提供帧率字段**。

本模块只依赖标准库（不导入 Qt），便于在任意环境做单元测试。
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse

from mobile.backend.commands import CommandError, apply_command, normalize_action, parse_action_params

#: 前端的静态资源目录（移动端界面）。
WEB_ROOT = Path(__file__).resolve().parent.parent / "web"

#: 允许通过 HTTP 提供的静态文件（白名单，避免目录穿越）。
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
}

#: MJPEG 的 multipart 分隔符。
MJPEG_BOUNDARY = "fastguardframe"

#: 单次等待新帧的最长时间（秒）；超时后重发上一帧，避免手机端看似掉线。
STREAM_WAIT_TIMEOUT = 5.0


class WebService:
    """HTTP 服务的轻量封装（便于测试里按需启停）。"""

    def __init__(self, host: str, port: int, hub: Any, bridge: Any) -> None:
        self.host = host
        self.port = int(port)
        self.hub = hub
        self.bridge = bridge
        self.httpd: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._bound_port = 0

    # ------------------------------------------------------------------ 生命周期
    def start(self) -> int:
        """启动 HTTP 服务，返回实际绑定的端口。"""
        handler = _make_handler(self.hub, self.bridge)
        self.httpd = ThreadingHTTPServer((self.host, self.port), handler)
        self.httpd.daemon_threads = True
        self._bound_port = int(self.httpd.server_address[1])
        self._thread = threading.Thread(target=self.httpd.serve_forever, name="web-server", daemon=True)
        self._thread.start()
        return self._bound_port

    def stop(self) -> None:
        if self.httpd is not None:
            try:
                self.httpd.shutdown()
                self.httpd.server_close()
            except Exception:  # pragma: no cover - 关闭顺序竞态
                pass
            self.httpd = None

    @property
    def bound_port(self) -> int:
        return self._bound_port

    def base_url(self, host: Optional[str] = None) -> str:
        return f"http://{host or self.host}:{self._bound_port}/"


def _json_bytes(payload: Dict[str, Any]) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


def _make_handler(hub: Any, bridge: Any):
    """构造请求处理器（把 hub/bridge 绑定进闭包）。"""

    class WebRequestHandler(BaseHTTPRequestHandler):
        server_version = "FastGuardWeb/1.0"
        protocol_version = "HTTP/1.1"

        # -------------------------------------------------------- 工具
        def _send(self, status: int, body: bytes, content_type: str, extra: Optional[Dict[str, str]] = None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            for key, value in (extra or {}).items():
                self.send_header(key, value)
            self.end_headers()
            if body:
                self.wfile.write(body)

        def _send_json(self, status: int, payload: Dict[str, Any]) -> None:
            self._send(status, _json_bytes(payload), "application/json; charset=utf-8")

        def _not_found(self) -> None:
            self._send_json(404, {"ok": False, "error": "未找到该接口"})

        def log_message(self, fmt: str, *args: Any) -> None:  # noqa: D102 - 静默，避免刷屏
            return

        # -------------------------------------------------------- GET
        def do_GET(self) -> None:  # noqa: N802 - http.server 约定
            path = urlparse(self.path).path
            if path in STATIC_FILES:
                self._serve_static(path)
                return
            if path == "/stream":
                self._serve_stream()
                return
            if path in ("/status", "/api/status"):
                self._send_json(200, _status_payload(bridge))
                return
            if path == "/bev":
                self._serve_bev()
                return
            self._not_found()

        def _serve_static(self, path: str) -> None:
            filename, content_type = STATIC_FILES[path]
            target = WEB_ROOT / filename
            if not target.is_file():
                self._send(500, f"缺少前端资源：{filename}".encode("utf-8"), "text/plain; charset=utf-8")
                return
            self._send(200, target.read_bytes(), content_type)

        def _serve_bev(self) -> None:
            _seq, _jpeg, bev = hub.latest_jpeg()
            if not bev:
                self._send_json(404, {"ok": False, "error": "BEV 未开启或暂无画面"})
                return
            self._send(200, bev, "image/jpeg")

        def _serve_stream(self) -> None:
            """MJPEG：持续推送同一份已编码的推理画面。"""
            self.send_response(200)
            self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary={MJPEG_BOUNDARY}")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()

            seq = -1
            while True:
                seq, jpeg, _bev = hub.wait_for_jpeg(seq, timeout=STREAM_WAIT_TIMEOUT)
                if not jpeg:
                    # 还没有首帧：稍后再试，保持连接
                    continue
                header = (
                    f"--{MJPEG_BOUNDARY}\r\n"
                    f"Content-Type: image/jpeg\r\n"
                    f"Content-Length: {len(jpeg)}\r\n\r\n"
                ).encode("ascii")
                try:
                    self.wfile.write(header)
                    self.wfile.write(jpeg)
                    self.wfile.write(b"\r\n")
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError, OSError):
                    return  # 客户端（浏览器）已关闭页面

        # -------------------------------------------------------- POST
        def do_POST(self) -> None:  # noqa: N802 - http.server 约定
            path = urlparse(self.path).path
            try:
                payload = self._read_json()
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
                return

            if path.startswith("/api/"):
                params = parse_action_params(payload)
                action = normalize_action(path[len("/api/"):] or params.get("action"))
                # 路径自带指令名时，body 里的 action 字段忽略
                params.pop("action", None)
                params.pop("cmd", None)
            else:
                try:
                    params = parse_action_params(payload)
                except CommandError as exc:
                    self._send_json(400, {"ok": False, "error": str(exc)})
                    return
                action = normalize_action(params.pop("action", ""))

            try:
                result = apply_command(bridge, action, params)
            except CommandError as exc:
                self._send_json(400, {"ok": False, "action": action, "error": str(exc)})
                return
            except Exception as exc:  # pragma: no cover - 引擎异常不应中断服务
                self._send_json(500, {"ok": False, "action": action, "error": f"指令执行失败: {exc}"})
                return

            status_code = 200 if result.get("ok", True) else 409
            payload = dict(result)
            payload["status"] = _status_payload(bridge)
            self._send_json(status_code, payload)

        def _read_json(self) -> Dict[str, Any]:
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                raise ValueError("Content-Length 非法")
            if length <= 0:
                return {}
            if length > 64 * 1024:
                raise ValueError("请求体过大")
            raw = self.rfile.read(length)
            if not raw:
                return {}
            try:
                data = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError(f"请求体不是合法 JSON: {exc}") from exc
            if not isinstance(data, dict):
                raise ValueError("请求体必须是 JSON 对象")
            return data

    return WebRequestHandler


def _status_payload(bridge: Any) -> Dict[str, Any]:
    """给前端的精简状态（**不含帧率**，符合移动端设计要求）。"""
    try:
        snapshot = dict(bridge.snapshot())
    except Exception:  # pragma: no cover - 引擎异常时仍要保持接口可用
        return {"state": "unknown", "error": "无法读取引擎状态"}

    # 明确剔除帧率相关字段：移动端不展示帧率
    for key in ("fps", "frame_rate", "fps_ema"):
        snapshot.pop(key, None)
    return snapshot


def create_service(host: str, port: int, hub: Any, bridge: Any) -> WebService:
    return WebService(host, port, hub, bridge)


def free_port() -> int:
    """取一个空闲端口（测试辅助）。"""
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def probe_status(url: str, timeout: float = 3.0) -> Optional[Dict[str, Any]]:
    """读取 ``/status``（测试与自检用）。"""
    import urllib.request

    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception:
        return None


#: 认为是"局域网可访问"的 IPv4 前缀（RFC1918 + link-local 之外的常见家用网段）。
PRIVATE_PREFIXES = ("192.168.", "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.2", "172.30.", "172.31.")


def _is_private_ipv4(address: str) -> bool:
    if not address or address.startswith("127."):
        return False
    parts = address.split(".")
    if len(parts) != 4 or not all(part.isdigit() for part in parts):
        return False
    if not all(0 <= int(part) <= 255 for part in parts):
        return False
    if address.startswith("169.254."):  # link-local，手机通常连不上
        return False
    if address.startswith("192.168.") or address.startswith("10."):
        return True
    if address.startswith("172."):
        second = int(parts[1])
        return 16 <= second <= 31
    return False


def local_ip() -> str:
    """尽量取本机在局域网中的 IPv4（用于打印手机可访问的地址）。

    只用 RFC1918 私网地址：某些机器（VPN / 虚拟网卡 / 特殊路由）会让
    "UDP connect" 技巧返回奇怪地址（实测遇到过 ``28.0.0.1``），因此这里逐个候选
    校验，取不到私网地址时回退到 ``127.0.0.1``。
    """
    import socket

    candidates = []

    # 1) 主机名解析出的地址（通常包含真实网卡地址）
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            candidates.append(info[4][0])
    except Exception:
        pass

    # 2) UDP connect 技巧（不实际发包）
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("8.8.8.8", 80))
            candidates.append(str(probe.getsockname()[0]))
    except Exception:
        pass

    for address in candidates:
        if _is_private_ipv4(address):
            return address
    return "127.0.0.1"


def describe_url(port: int) -> Tuple[str, str]:
    """返回 ``(本机地址, 局域网地址)``。"""
    lan_ip = local_ip()
    return f"http://127.0.0.1:{port}/", f"http://{lan_ip}:{port}/"
