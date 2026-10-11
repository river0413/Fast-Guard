"""FastGuard 推理服务（移动端上位机侧适配层）。

与既有架构的关系
----------------
* 推理仍然由 PC 侧既有的 :class:`core.video_thread.VideoThread` 完成，
  **算法与线程结构不做任何改动**，桌面端 ``main.py`` 也完全不受影响；
* 本模块是**新增**的一层适配：把引擎已有的信号转成 JPEG + JSON 状态流，
  并通过 TCP 接受移动端的少量控制指令（摄像头序号 / 阈值 / 推理图片大小 / BEV）。

启动方式::

    python -m mobile.backend.frame_server --host 0.0.0.0 --port 8765 --source 0
"""

from __future__ import annotations

import argparse
import os
import signal
import socket
import socketserver
import sys
import threading
import time
from typing import Any, Dict, List, Optional, Set

# 导入顺序：先 engine_bridge（内部先加载 ultralytics / torch），再导入 PyQt5，
# 与桌面端 main.py 保持一致，避免 torch DLL 初始化失败。
from mobile import protocol
from mobile.backend.commands import CommandError, apply_command
from mobile.backend.engine_bridge import DEFAULT_MODEL_PATH, EngineBridge, normalize_source
from mobile.backend.frame_hub import FrameHub

from PyQt5 import QtCore  # noqa: E402

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

#: 没有新帧时，服务端最多阻塞多久就回一次保活/状态消息。
FRAME_WAIT_TIMEOUT = 3.0


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}][pid {os.getpid()}] {message}", flush=True)


class FrameServer(socketserver.ThreadingTCPServer):
    """为每个客户端开一条线程，广播同一份已编码画面。"""

    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address, hub: FrameHub, bridge: EngineBridge) -> None:
        self.hub = hub
        self.bridge = bridge
        self.stopping = False
        self._clients: Set["FrameRequestHandler"] = set()
        self._clients_lock = threading.Lock()
        super().__init__(address, FrameRequestHandler)

    # --- 客户端登记 ---------------------------------------------------------
    def add_client(self, handler: "FrameRequestHandler") -> None:
        with self._clients_lock:
            self._clients.add(handler)

    def remove_client(self, handler: "FrameRequestHandler") -> None:
        with self._clients_lock:
            self._clients.discard(handler)

    def client_count(self) -> int:
        with self._clients_lock:
            return len(self._clients)

    def stop_service(self) -> None:
        self.stopping = True
        self.hub.close()
        with self._clients_lock:
            clients = list(self._clients)
        for handler in clients:
            handler.close()
        try:
            self.shutdown()
        except Exception:  # pragma: no cover - 关闭顺序竞态
            pass
        self.server_close()


class FrameRequestHandler(socketserver.BaseRequestHandler):
    """单客户端：一个线程推送画面，一个线程读取控制指令。"""

    server: FrameServer

    def setup(self) -> None:
        self._send_lock = threading.Lock()
        self._closed = False
        try:
            self.request.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:  # pragma: no cover - 个别平台不支持
            pass
        self.server.add_client(self)

    def handle(self) -> None:
        log(f"客户端已连接 {self.client_address[0]}:{self.client_address[1]}")
        reader = threading.Thread(target=self._read_commands, name="cmd-reader", daemon=True)
        reader.start()

        frame_seq = -1
        status_seq = -1
        try:
            # 连接后先回一份"实时快照"（含引擎状态 / 视频源错误），便于界面立即给出提示。
            self._send_many([protocol.make_status(self.server.bridge.snapshot())])
            while not self.server.stopping and not self._closed:
                frame_seq, status_seq, messages = self.server.hub.wait_for_update(
                    frame_seq, status_seq, FRAME_WAIT_TIMEOUT
                )
                if messages:
                    self._send_many(messages)
                else:
                    # 长时间既无新帧也无状态变化时，推送一份最新快照（含错误提示与运行时长）。
                    self._send_many([protocol.make_status(self.server.bridge.snapshot())])
        except OSError:
            pass  # 客户端正常/异常断开
        finally:
            self.close()
            log(f"客户端已断开 {self.client_address[0]}:{self.client_address[1]}")

    # ------------------------------------------------------------------ 发送
    def _send_many(self, messages: List[bytes]) -> None:
        with self._send_lock:
            for message in messages:
                self.request.sendall(message)

    def close(self) -> None:
        self._closed = True
        self.server.remove_client(self)
        try:
            self.request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    # ------------------------------------------------------------------ 接收
    def _read_commands(self) -> None:
        try:
            fp = self.request.makefile("rb")
        except OSError:
            return
        try:
            while not self.server.stopping:
                header, _ = protocol.read_message(fp)
                self._dispatch(header)
        except (ConnectionError, OSError, ValueError, protocol.ProtocolError):
            pass
        finally:
            try:
                fp.close()
            except OSError:  # pragma: no cover
                pass
            self.close()

    def _dispatch(self, header: Dict[str, Any]) -> None:
        message_type = str(header.get("type", ""))
        if message_type != protocol.TYPE_CMD:
            self._send_many([protocol.make_error(f"不支持的消息类型: {message_type}")])
            return

        action = str(header.get("action", ""))
        params = {key: value for key, value in header.items() if key not in ("type", "action", "v")}
        try:
            if action == protocol.CMD_SET_SOURCE:
                log(f"切换视频源 → {params.get('index')}（引擎将重新打开视频源）")
            # 校验与执行统一走 commands.apply_command，确保与 Web 通道行为一致
            result = apply_command(self.server.bridge, action, params)
            if not result.get("ok", True):
                reason = result.get("reason", "")
                log(f"引擎拒绝了指令 {action}：{reason}")
                extra = {k: v for k, v in result.items() if k not in ("ok", "action", "reason")}
                self._send_many([protocol.make_ack(action, ok=False, reason=reason, **extra)])
                self._send_many([protocol.make_status(self.server.bridge.snapshot())])
                return
            extra = {k: v for k, v in result.items() if k not in ("ok", "action")}
            self._ack(action, **extra)
        except CommandError as exc:
            self._send_many([protocol.make_error(f"指令参数错误: {exc}", action)])
        except Exception as exc:  # pragma: no cover - 引擎异常不应断开连接
            self._send_many([protocol.make_error(f"指令执行失败: {exc}", action)])

    def _ack(self, action: str, **extra: Any) -> None:
        status = self.server.bridge.snapshot()
        self._send_many([protocol.make_ack(action, **extra), protocol.make_status(status)])


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FastGuard 移动端推理服务")
    parser.add_argument("--host", default="0.0.0.0", help="监听地址（默认 0.0.0.0，手机需可访问）")
    parser.add_argument("--port", type=int, default=protocol.DEFAULT_PORT, help="监听端口")
    parser.add_argument("--source", default="0", help="摄像头序号（0=后置 / 1=前置），或视频文件路径")
    parser.add_argument("--model", default=DEFAULT_MODEL_PATH, help="YOLO 权重路径")
    parser.add_argument("--weak-conf", type=float, default=0.38, help="低置信度阈值")
    parser.add_argument("--edge-strength", type=float, default=28.0, help="边缘强度阈值")
    parser.add_argument(
        "--inference-size",
        type=int,
        default=protocol.DEFAULT_INFERENCE_SIZE,
        choices=list(protocol.INFERENCE_SIZE_CHOICES),
        help="推理图片大小 (imgsz)",
    )
    parser.add_argument("--jpeg-quality", type=int, default=80, help="JPEG 编码质量")
    parser.add_argument(
        "--web-port",
        type=int,
        default=0,
        help="同时开启手机浏览器直连的 Web 界面端口（0 = 关闭；例如 8080）",
    )
    parser.add_argument("--web-host", default="0.0.0.0", help="Web 界面监听地址")
    return parser.parse_args(argv)


def build_service(args: argparse.Namespace):
    """创建 hub / bridge / server（便于测试单独复用）。"""
    model_path = args.model if os.path.isabs(args.model) else os.path.join(PROJECT_ROOT, args.model)
    hub = FrameHub(quality=args.jpeg_quality)
    bridge = EngineBridge(
        model_path=model_path,
        source=normalize_source(args.source),
        weak_conf=args.weak_conf,
        edge_strength=args.edge_strength,
        inference_size=args.inference_size,
        on_frame=hub.update,
        on_status=hub.publish_status,
    )
    server = FrameServer((args.host, args.port), hub=hub, bridge=bridge)
    return hub, bridge, server


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    app = QtCore.QCoreApplication.instance() or QtCore.QCoreApplication([sys.argv[0] if sys.argv else "frame_server"])

    hub, bridge, server = build_service(args)
    log(f"推理服务启动于 {args.host}:{args.port}，摄像头序号 {args.source}，推理图片大小 {bridge.inference_size}")
    bridge.start()
    server_thread = threading.Thread(target=server.serve_forever, name="tcp-server", daemon=True)
    server_thread.start()

    # 可选的 Web 界面：手机浏览器直接打开即可，无需安装 APK
    web_service = None
    if args.web_port:
        from mobile.backend.web_ui import create_service, describe_url

        web_service = create_service(args.web_host, args.web_port, hub, bridge)
        bound = web_service.start()
        local_url, lan_url = describe_url(bound)
        log(f"Web 界面已开启：本机 {local_url}　手机 {lan_url}")

    # 让 Qt 事件循环周期性回到 Python 解释器，以便响应 Ctrl+C。
    ticker = QtCore.QTimer()
    ticker.start(200)
    ticker.timeout.connect(lambda: None)

    def _shutdown(*_args: Any) -> None:
        log("正在停止推理服务…")
        app.quit()

    signal.signal(signal.SIGINT, _shutdown)
    try:
        app.exec_()
    finally:
        server.stop_service()
        if web_service is not None:
            web_service.stop()
        bridge.stop()
        log("推理服务已停止")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
