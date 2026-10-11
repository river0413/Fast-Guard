"""推理画面的中转缓存：只保留最新一帧，并为所有客户端复用一次 JPEG 编码。

引擎线程把画面 ``update()`` 进来后立刻返回；真正的 JPEG 编码放在独立的
编码线程里完成，因此**不会拖慢 ``VideoThread`` 的推理循环**（符合
"保持推理" 的约束）。每个客户端只需要等待比自己已收到的序号更新的帧，
再取走同一份已编码数据即可。
"""

from __future__ import annotations

import threading
import time
from typing import Any, Dict, List, Optional, Tuple

from PyQt5 import QtCore, QtGui

from mobile import protocol


def encode_jpeg(image: QtGui.QImage, quality: int = 80) -> bytes:
    """把 QImage 编码为 JPEG 字节流。"""
    buffer = QtCore.QBuffer()
    buffer.open(QtCore.QIODevice.WriteOnly)
    if not image.save(buffer, "JPG", quality):
        raise RuntimeError("JPEG 编码失败")
    return bytes(buffer.data())


class FrameHub:
    """最新帧缓存 + 单次 JPEG 编码 + 多客户端广播。"""

    def __init__(self, quality: int = 80) -> None:
        self._quality = int(quality)
        self._cond = threading.Condition()
        self._image: Optional[QtGui.QImage] = None
        self._bev: Optional[QtGui.QImage] = None
        self._status: Dict[str, Any] = {}
        self._error: Optional[str] = None
        self._raw_seq = 0
        self._encoded_seq = -1
        self._status_seq = 0
        self._encoded: List[bytes] = []
        # 原始 JPEG 负载：供 Web（MJPEG）复用同一份编码结果，避免二次编码
        self._jpeg: bytes = b""
        self._bev_jpeg: Optional[bytes] = None
        self._closed = False
        self._encoder = threading.Thread(target=self._encode_loop, name="frame-encoder", daemon=True)
        self._encoder.start()

    # ------------------------------------------------------------------ 写入端
    def update(self, image: QtGui.QImage, bev: Optional[QtGui.QImage], status: Dict[str, Any]) -> None:
        """引擎线程调用：记录最新画面（不做编码）。"""
        with self._cond:
            self._image = image
            self._bev = bev
            self._status = dict(status or {})
            self._raw_seq += 1
            self._cond.notify_all()

    def publish_status(self, status: Dict[str, Any], error: Optional[str] = None) -> None:
        """状态变化（例如摄像头打不开）时调用。"""
        with self._cond:
            self._status = dict(status or {})
            self._error = error
            self._status_seq += 1
            self._cond.notify_all()

    def close(self) -> None:
        with self._cond:
            self._closed = True
            self._cond.notify_all()

    # ------------------------------------------------------------------ 读取端
    def wait_for_update(
        self,
        after_frame_seq: int,
        after_status_seq: int,
        timeout: float = 5.0,
    ) -> Tuple[int, int, List[bytes]]:
        """等待新帧或新状态，返回 ``(frame_seq, status_seq, messages)``。

        超时或服务关闭时返回已带的消息（可能为空），调用方可据此发送保活包。
        """
        deadline = time.time() + timeout
        with self._cond:
            while not self._closed:
                if self._encoded_seq > after_frame_seq or self._status_seq > after_status_seq:
                    break
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                self._cond.wait(remaining)

            if self._closed:
                return after_frame_seq, after_status_seq, []

            messages: List[bytes] = []
            frame_seq = after_frame_seq
            status_seq = after_status_seq
            if self._encoded_seq > after_frame_seq:
                messages.extend(self._encoded)
                frame_seq = self._encoded_seq
            if self._status_seq > after_status_seq:
                messages.append(protocol.make_status(self._status_payload_locked()))
                status_seq = self._status_seq
            return frame_seq, status_seq, messages

    def latest_frame_seq(self) -> int:
        with self._cond:
            return self._encoded_seq

    def wait_for_jpeg(self, after_seq: int, timeout: float = 5.0) -> Tuple[int, bytes, Optional[bytes]]:
        """等待比 ``after_seq`` 更新的帧，返回 ``(seq, 推理画面 JPEG, BEV JPEG 或 None)``。

        与 :meth:`wait_for_update` 共用同一份编码结果，因此 Web 端（MJPEG）不会
        额外增加推理开销。超时则返回当前（可能未更新）的内容。
        """
        deadline = time.time() + timeout
        with self._cond:
            while not self._closed and self._encoded_seq <= after_seq:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                self._cond.wait(remaining)
            return self._encoded_seq, self._jpeg, self._bev_jpeg

    def latest_jpeg(self) -> Tuple[int, bytes, Optional[bytes]]:
        with self._cond:
            return self._encoded_seq, self._jpeg, self._bev_jpeg

    def status(self) -> Dict[str, Any]:
        with self._cond:
            return self._status_payload_locked()

    def _status_payload_locked(self) -> Dict[str, Any]:
        payload = dict(self._status)
        if self._error:
            payload["error"] = self._error
        return payload

    # ------------------------------------------------------------------ 编码线程
    def _encode_loop(self) -> None:
        while True:
            with self._cond:
                while not self._closed and (self._raw_seq == self._encoded_seq or self._image is None):
                    self._cond.wait(0.5)
                if self._closed:
                    return
                image = self._image
                bev = self._bev
                status = dict(self._status)
                seq = self._raw_seq
            try:
                jpeg = encode_jpeg(image, self._quality) if image is not None else b""
                bev_jpeg = encode_jpeg(bev, self._quality) if bev is not None else None
                messages = [
                    protocol.encode_message(
                        {"type": protocol.TYPE_FRAME, "seq": seq, "status": status}, jpeg
                    )
                ]
                if bev_jpeg is not None:
                    messages.append(
                        protocol.encode_message({"type": protocol.TYPE_BEV, "seq": seq}, bev_jpeg)
                    )
                error: Optional[str] = None
            except Exception as exc:  # pragma: no cover - 编码失败时保留上一帧
                messages = []
                jpeg = b""
                bev_jpeg = None
                error = f"画面编码失败: {exc}"
            with self._cond:
                if messages:
                    self._encoded = messages
                    self._encoded_seq = seq
                    self._jpeg = jpeg
                    self._bev_jpeg = bev_jpeg
                if error:
                    self._error = error
                self._cond.notify_all()
