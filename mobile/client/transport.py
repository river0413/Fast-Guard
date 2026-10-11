"""移动端到推理服务的网络客户端（PySide6 / Qt6）。

在独立线程中维护与服务端的长连接：
* 接收 AI 推理画面（JPEG）与引擎状态；
* 汇总为 Qt 信号交给界面线程；
* 把界面上的控制指令（摄像头、阈值、推理图片大小、BEV）排队后发送。

移动端自身**不做推理**，只负责显示与参数下发，这正是"卸载推理"的含义。
"""

from __future__ import annotations

import socket
import threading
import time
from collections import deque
from typing import Any, Deque, Dict, Optional, Tuple

from PySide6 import QtCore, QtGui

from mobile import protocol

#: 连接状态：界面右上角的"卸载推理"徽标据此显示。
STATE_CONNECTING = "connecting"
STATE_ONLINE = "online"
STATE_STALLED = "stalled"
STATE_OFFLINE = "offline"

#: 超过该秒数没有新帧则视为画面停滞。
STALL_AFTER_SECONDS = 3.0

_RECEIVE_CHUNK = 64 * 1024
_SOCKET_TIMEOUT = 0.5


class FrameClient(QtCore.QThread):
    """推理画面接收线程。"""

    frame_received = QtCore.Signal(QtGui.QImage, object)   # (推理画面, BEV 或 None)
    status_received = QtCore.Signal(dict)
    link_state_changed = QtCore.Signal(str, str)           # (状态, 说明文字)
    command_result = QtCore.Signal(str, bool, str)         # (指令, 是否成功, 说明)
    error_received = QtCore.Signal(str)

    def __init__(self, host: str = protocol.DEFAULT_HOST, port: int = protocol.DEFAULT_PORT, parent=None) -> None:
        super().__init__(parent)
        self._endpoint = (str(host), int(port))
        self._endpoint_lock = threading.Lock()
        self._outbox: Deque[bytes] = deque()
        self._outbox_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._socket_lock = threading.Lock()
        self._socket: Optional[socket.socket] = None
        self._state = ""
        self._bev_image: Optional[QtGui.QImage] = None

    # ------------------------------------------------------------------ 线程控制
    def run(self) -> None:  # noqa: D102 - QThread 入口
        while not self._stop_event.is_set():
            host, port = self.endpoint()
            sock = self._connect(host, port)
            if sock is None:
                self._emit_state(STATE_OFFLINE, f"无法连接 {host}:{port}")
                self._stop_event.wait(1.5)
                continue

            self._emit_state(STATE_CONNECTING, f"已连接 {host}:{port}，等待推理画面")
            try:
                self._receive_loop(sock)
            except protocol.ProtocolError as exc:
                self.error_received.emit(f"协议错误：{exc}")
            except OSError as exc:
                self.error_received.emit(f"连接中断：{exc}")
            finally:
                self._close_socket()
            self._emit_state(STATE_OFFLINE, "推理服务已断开")
            self._stop_event.wait(1.0)

        self._emit_state(STATE_OFFLINE, "已停止")

    def stop(self, timeout_ms: int = 3000) -> None:
        self._stop_event.set()
        self._close_socket()
        if self.isRunning():
            self.wait(timeout_ms)

    def _connect(self, host: str, port: int) -> Optional[socket.socket]:
        try:
            sock = socket.create_connection((host, port), timeout=3.0)
        except OSError:
            return None
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(_SOCKET_TIMEOUT)
        with self._socket_lock:
            self._socket = sock
        return sock

    def _close_socket(self) -> None:
        with self._socket_lock:
            sock, self._socket = self._socket, None
        if sock is not None:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:  # pragma: no cover - 已断开
                pass
            try:
                sock.close()
            except OSError:  # pragma: no cover
                pass

    # ------------------------------------------------------------------ 收发
    def _receive_loop(self, sock: socket.socket) -> None:
        framer = protocol.BytesFramer()
        last_frame_at = time.time()
        reported_stall = False
        while not self._stop_event.is_set():
            self._flush_outbox(sock)
            try:
                chunk = sock.recv(_RECEIVE_CHUNK)
            except socket.timeout:
                if not reported_stall and (time.time() - last_frame_at) > STALL_AFTER_SECONDS:
                    reported_stall = True
                    self._emit_state(STATE_STALLED, "推理服务无新画面")
                continue
            if not chunk:
                return  # 服务端关闭
            for header, payload in framer.feed(chunk):
                message_type = str(header.get("type", ""))
                if message_type == protocol.TYPE_FRAME:
                    image = self._decode(payload)
                    if image is not None:
                        last_frame_at = time.time()
                        reported_stall = False
                        if self._state != STATE_ONLINE:
                            self._emit_state(STATE_ONLINE, "推理运算已在服务端完成")
                        self.frame_received.emit(image, self._bev_image)
                elif message_type == protocol.TYPE_BEV:
                    self._bev_image = self._decode(payload)
                elif message_type == protocol.TYPE_STATUS:
                    self.status_received.emit(dict(header))
                elif message_type == protocol.TYPE_ACK:
                    self.command_result.emit(
                        str(header.get("action", "")),
                        bool(header.get("ok", True)),
                        str(header.get("reason", "") or header.get("message", "")),
                    )
                elif message_type == protocol.TYPE_ERROR:
                    self.error_received.emit(str(header.get("message", "服务端错误")))

    def _flush_outbox(self, sock: socket.socket) -> None:
        while True:
            with self._outbox_lock:
                if not self._outbox:
                    return
                message = self._outbox.popleft()
            sock.sendall(message)

    @staticmethod
    def _decode(payload: bytes) -> Optional[QtGui.QImage]:
        if not payload:
            return None
        image = QtGui.QImage.fromData(payload)
        return None if image.isNull() else image

    # ------------------------------------------------------------------ 对外接口
    def endpoint(self) -> Tuple[str, int]:
        with self._endpoint_lock:
            return self._endpoint

    def set_endpoint(self, host: str, port: int) -> None:
        """切换服务地址；下一次重连生效。"""
        with self._endpoint_lock:
            self._endpoint = (str(host), int(port))
        self._close_socket()

    def send_command(self, action: str, **params: Any) -> None:
        """把控制指令排队发送（线程安全，可从界面线程调用）。"""
        message = protocol.make_command(action, **params)
        with self._outbox_lock:
            self._outbox.append(message)

    def link_state(self) -> str:
        return self._state

    def _emit_state(self, state: str, detail: str = "") -> None:
        if state == self._state and not detail:
            return
        self._state = state
        self.link_state_changed.emit(state, detail)


def describe_link_state(state: str) -> Tuple[str, str]:
    """把连接状态映射为徽标文案与颜色（供界面层复用）。"""
    if state == STATE_ONLINE:
        return "运行中", "#10b981"
    if state == STATE_STALLED:
        return "画面停滞", "#f59e0b"
    if state == STATE_CONNECTING:
        return "连接中", "#f59e0b"
    return "已断开", "#ef4444"
