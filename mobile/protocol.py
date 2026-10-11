"""FastGuard 移动端 ↔ 推理服务 的轻量消息协议。

该模块同时被服务端（PyQt5 进程）和客户端（PySide6 进程）导入，
因此**不依赖任何 Qt 绑定**，只用标准库。

线格式（大端）：

    +--------+------------+-------------+------------+-----------+
    | MAGIC  | header_len | header JSON | payload_len|  payload  |
    | 4 字节 |  uint32    |  utf-8      |   uint32   |  二进制   |
    +--------+------------+-------------+------------+-----------+

``header`` 必须包含 ``type`` 字段（见下方 TYPE_* 常量），并与 ``payload``
的内容保持一致：``frame`` / ``bev`` 的 payload 是 JPEG 数据，其余消息
的 payload 为空。
"""

from __future__ import annotations

import json
import struct
from typing import Any, BinaryIO, Dict, Tuple

MAGIC = b"FGMP"
_VERSION = 1

_HEADER_STRUCT = struct.Struct(">I")
MAX_HEADER_BYTES = 64 * 1024
MAX_PAYLOAD_BYTES = 16 * 1024 * 1024

# --- 消息类型 ---------------------------------------------------------------
TYPE_FRAME = "frame"    # 服务端 -> 客户端：AI 推理画面（JPEG）
TYPE_BEV = "bev"        # 服务端 -> 客户端：IPM 俯视图（JPEG，可选）
TYPE_STATUS = "status"  # 双向：引擎状态快照
TYPE_CMD = "cmd"        # 客户端 -> 服务端：控制指令
TYPE_ACK = "ack"        # 服务端 -> 客户端：指令执行结果
TYPE_ERROR = "error"    # 服务端 -> 客户端：错误

# --- 控制指令 ---------------------------------------------------------------
CMD_SET_SOURCE = "set_source"                    # {"index": int} 切换摄像头
CMD_SET_THRESHOLDS = "set_thresholds"            # {"weak_conf": float, "edge_strength": float}
CMD_SET_INFERENCE_SIZE = "set_inference_size"    # {"size": int} 推理图片大小
CMD_SET_BEV = "set_bev"                          # {"enabled": bool}
CMD_PING = "ping"

#: 推理图片大小（YOLO ``imgsz``）可选项，与 ``core.video_thread`` 的默认值 320 保持一致。
INFERENCE_SIZE_CHOICES: Tuple[int, ...] = (320, 416, 512, 640)
DEFAULT_INFERENCE_SIZE = 320

#: 移动端可切换的摄像头序号（手机端约定 0=后置，1=前置）。
CAMERA_CHOICES: Tuple[int, ...] = (0, 1, 2, 3)

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8765

PROTOCOL_VERSION = _VERSION


class ProtocolError(RuntimeError):
    """收到不符合协议的数据。"""


def encode_message(header: Dict[str, Any], payload: bytes = b"") -> bytes:
    """把 ``header`` 与 ``payload`` 打包成一条完整消息。"""
    header = dict(header)
    header.setdefault("v", _VERSION)
    blob = json.dumps(header, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(blob) > MAX_HEADER_BYTES:
        raise ProtocolError("header 过大")
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError("payload 过大")
    return b"".join(
        (
            MAGIC,
            _HEADER_STRUCT.pack(len(blob)),
            blob,
            _HEADER_STRUCT.pack(len(payload)),
            payload,
        )
    )


def _read_exact(fp: BinaryIO, size: int) -> bytes:
    data = fp.read(size)
    if data is None or len(data) != size:
        raise ConnectionError("连接已关闭")
    return data


def read_message(fp: BinaryIO) -> Tuple[Dict[str, Any], bytes]:
    """从流中读取一条消息，返回 ``(header, payload)``。

    连接关闭或数据损坏时抛出 ``ConnectionError`` / ``ProtocolError``。
    """
    magic = _read_exact(fp, len(MAGIC))
    if magic != MAGIC:
        raise ProtocolError("魔数不匹配")

    (header_len,) = _HEADER_STRUCT.unpack(_read_exact(fp, 4))
    if header_len > MAX_HEADER_BYTES:
        raise ProtocolError("header 长度非法")
    raw_header = _read_exact(fp, header_len) if header_len else b"{}"
    try:
        header = json.loads(raw_header.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:  # pragma: no cover - 防御性
        raise ProtocolError(f"header JSON 解析失败: {exc}") from exc

    (payload_len,) = _HEADER_STRUCT.unpack(_read_exact(fp, 4))
    if payload_len > MAX_PAYLOAD_BYTES:
        raise ProtocolError("payload 长度非法")
    payload = _read_exact(fp, payload_len) if payload_len else b""
    return header, payload


def make_command(action: str, **params: Any) -> bytes:
    """构造一条客户端控制指令。"""
    header: Dict[str, Any] = {"type": TYPE_CMD, "action": action}
    header.update(params)
    return encode_message(header)


def make_status(status: Dict[str, Any]) -> bytes:
    """构造一条状态消息（状态字段直接内联在 header 中）。"""
    header: Dict[str, Any] = {"type": TYPE_STATUS}
    header.update(status)
    return encode_message(header)


def make_error(message: str, action: str = "") -> bytes:
    header: Dict[str, Any] = {"type": TYPE_ERROR, "message": message}
    if action:
        header["action"] = action
    return encode_message(header)


def make_ack(action: str, ok: bool = True, **extra: Any) -> bytes:
    header: Dict[str, Any] = {"type": TYPE_ACK, "action": action, "ok": bool(ok)}
    header.update(extra)
    return encode_message(header)


class BytesFramer:
    """把任意分片的字节流切分成协议消息（客户端非阻塞读取时使用）。"""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, chunk: bytes) -> list:
        """喂入一段字节，返回本次能够解析出的 ``[(header, payload), ...]``。"""
        if chunk:
            self._buffer.extend(chunk)
        messages = []
        while True:
            parsed = self._try_parse()
            if parsed is None:
                return messages
            messages.append(parsed)

    def _try_parse(self) -> Tuple[Dict[str, Any], bytes] | None:
        buffer = self._buffer
        if len(buffer) < 8:
            return None
        if bytes(buffer[:4]) != MAGIC:
            raise ProtocolError("魔数不匹配")
        (header_len,) = _HEADER_STRUCT.unpack(bytes(buffer[4:8]))
        if header_len > MAX_HEADER_BYTES:
            raise ProtocolError("header 长度非法")
        head_end = 8 + header_len
        if len(buffer) < head_end + 4:
            return None
        (payload_len,) = _HEADER_STRUCT.unpack(bytes(buffer[head_end:head_end + 4]))
        if payload_len > MAX_PAYLOAD_BYTES:
            raise ProtocolError("payload 长度非法")
        total = head_end + 4 + payload_len
        if len(buffer) < total:
            return None
        try:
            header = json.loads(bytes(buffer[8:head_end]).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:  # pragma: no cover - 防御性
            raise ProtocolError(f"header JSON 解析失败: {exc}") from exc
        payload = bytes(buffer[head_end + 4:total])
        del buffer[:total]
        return header, payload
