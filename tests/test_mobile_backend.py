"""推理服务端（PyQt5 侧）的端到端测试。

**进程隔离**：``mobile.backend.*`` / ``core.video_thread`` 使用 PyQt5，
而移动端界面使用 PySide6；同一进程加载两套 Qt 绑定会崩溃，因此本文件的
所有断言都通过独立子进程 + TCP 协议完成，本进程只导入 ``mobile.protocol``。

默认跳过（需要加载 PyTorch / Ultralytics / YOLO 权重，耗时较长）。启用方式::

    $env:FASTGUARD_MOBILE_E2E=1
    pytest tests/test_mobile_backend.py -v

覆盖内容：
* 服务端启动、首帧状态推送、控制指令 ack（阈值 / 推理图片大小 / BEV / ping）；
* 视频源不可用时能上报错误状态；
* 真实视频源下能持续收到 JPEG 推理画面，并能按需收到 BEV 画面；
* ``inference_size`` 运行时开关（默认 320）确实生效。
"""

from __future__ import annotations

import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from mobile import protocol  # noqa: E402

#: 允许的启动等待时间（torch / ultralytics / 模型加载较慢）。
STARTUP_DEADLINE = 180.0
#: 单条消息等待时间。
MESSAGE_DEADLINE = 90.0

WEIGHTS = PROJECT_ROOT / "assets" / "weights" / "yolo11n.pt"

ENABLED = os.environ.get("FASTGUARD_MOBILE_E2E", "").strip().lower() not in ("", "0", "false", "no")

pytestmark = [
    pytest.mark.skipif(not ENABLED, reason="设置 FASTGUARD_MOBILE_E2E=1 后运行推理服务端到端测试"),
    pytest.mark.skipif(not WEIGHTS.exists(), reason=f"缺少推理权重 {WEIGHTS}"),
]


# ====================================================================== 工具
class ServerProcess:
    """被测的推理服务子进程 + 一个已连接的客户端 socket。"""

    def __init__(
        self,
        source: Any,
        inference_size: int = 320,
        jpeg_quality: int = 70,
        model: Optional[Path] = None,
    ) -> None:
        self.port = _free_port()
        self.log_path = PROJECT_ROOT / "logs" / "mobile_backend_test.log"
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log_handle = open(self.log_path, "w", encoding="utf-8")
        command = [
            sys.executable,
            "-m",
            "mobile.backend.frame_server",
            "--host",
            "127.0.0.1",
            "--port",
            str(self.port),
            "--source",
            str(source),
            "--inference-size",
            str(inference_size),
            "--jpeg-quality",
            str(jpeg_quality),
        ]
        if model is not None:
            command += ["--model", str(model)]
        self.process = subprocess.Popen(
            command,
            cwd=str(PROJECT_ROOT),
            stdout=self._log_handle,
            stderr=subprocess.STDOUT,
        )
        self.socket: Optional[socket.socket] = None
        self._framer = protocol.BytesFramer()
        self._pending: List[Tuple[Dict[str, Any], bytes]] = []

    # --- 连接 ---------------------------------------------------------------
    def connect(self, deadline: float = STARTUP_DEADLINE) -> None:
        end = time.time() + deadline
        last_error: Optional[Exception] = None
        while time.time() < end:
            if self.process.poll() is not None:
                raise AssertionError(f"推理服务提前退出（code={self.process.returncode}）\n{self.tail_log()}")
            try:
                self.socket = socket.create_connection(("127.0.0.1", self.port), timeout=0.5)
                self.socket.settimeout(1.0)
                return
            except OSError as exc:
                last_error = exc
                time.sleep(0.5)
        raise AssertionError(f"无法连接推理服务：{last_error}\n{self.tail_log()}")

    # --- 收发 ---------------------------------------------------------------
    def send(self, action: str, **params: Any) -> None:
        assert self.socket is not None
        self.socket.sendall(protocol.make_command(action, **params))

    def wait_for(
        self,
        predicate: Callable[[Dict[str, Any]], bool],
        deadline: float = MESSAGE_DEADLINE,
        description: str = "",
    ) -> Tuple[Dict[str, Any], bytes]:
        """等待满足条件的消息；期间收到的消息会缓存下来供后续断言。"""
        for header, payload in self._pending:
            if predicate(header):
                self._pending.remove((header, payload))
                return header, payload

        end = time.time() + deadline
        while time.time() < end:
            for header, payload in self._receive():
                if predicate(header):
                    return header, payload
                self._pending.append((header, payload))
        raise AssertionError(
            f"等待消息超时：{description or predicate}\n已缓存：{self._pending}\n{self.tail_log()}"
        )

    def _receive(self) -> List[Tuple[Dict[str, Any], bytes]]:
        assert self.socket is not None
        try:
            chunk = self.socket.recv(65536)
        except socket.timeout:
            return []
        if not chunk:
            raise AssertionError(f"服务端关闭了连接\n{self.tail_log()}")
        return self._framer.feed(chunk)

    def tail_log(self, lines: int = 25) -> str:
        try:
            content = self.log_path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:  # pragma: no cover
            return "(无日志)"
        return "\n".join(content[-lines:])

    def close(self) -> None:
        if self.socket is not None:
            try:
                self.socket.close()
            except OSError:  # pragma: no cover
                pass
            self.socket = None
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:  # pragma: no cover
                self.process.kill()
        self._log_handle.close()


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


@pytest.fixture
def fp32_model(tmp_path: Path) -> Path:
    """把 FP32 权重复制到临时目录。

    若权重旁边存在 ``*_int8_openvino_model`` 目录，引擎会走 INT8 分支；
    临时目录中没有该目录，可避免触发 Ultralytics 的 OpenVINO 自动安装，
    让测试更快、更可重复（推理链路本身不变）。
    """
    target = tmp_path / "yolo11n.pt"
    shutil.copy2(WEIGHTS, target)
    return target


def _make_test_video(path: Path, frames: int = 60, fps: int = 20) -> Optional[Path]:
    """用 OpenCV 生成一段合成视频（避免依赖摄像头或测试素材）。"""
    try:
        import cv2
        import numpy as np
    except ImportError:  # pragma: no cover - 依赖缺失
        return None

    width, height = 480, 360
    writer = cv2.VideoWriter(str(path), cv2.VideoWriter_fourcc(*"MJPG"), fps, (width, height))
    if not writer.isOpened():  # pragma: no cover - 编码器缺失
        return None
    try:
        for index in range(frames):
            frame = np.full((height, width, 3), 40, dtype=np.uint8)
            x = 40 + index * 5
            cv2.rectangle(frame, (x, 150), (x + 60, 260), (255, 255, 255), -1)
            cv2.line(frame, (0, 300), (width, 300), (0, 0, 255), 2)
            writer.write(frame)
    finally:
        writer.release()
    return path if path.exists() and path.stat().st_size > 0 else None


# ====================================================================== 用例
def test_server_handles_control_commands_without_video_source(fp32_model: Path):
    """视频源不可用时：服务端仍要响应控制指令，并给出错误状态。"""
    server = ServerProcess(source=99, model=fp32_model)
    try:
        server.connect()

        status, _ = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_STATUS, deadline=30.0, description="首个状态消息"
        )
        assert status["source"] == 99
        assert status["inference_size"] == protocol.DEFAULT_INFERENCE_SIZE
        assert "state" in status

        server.send(protocol.CMD_PING)
        ack, _ = server.wait_for(
            lambda header: header.get("action") == protocol.CMD_PING, deadline=20.0, description="ping ack"
        )
        assert ack["type"] == protocol.TYPE_ACK
        assert ack["ok"] is True

        server.send(protocol.CMD_SET_THRESHOLDS, weak_conf=0.55, edge_strength=33.0)
        ack, _ = server.wait_for(
            lambda header: header.get("action") == protocol.CMD_SET_THRESHOLDS, deadline=20.0
        )
        assert ack["weak_conf"] == pytest.approx(0.55)
        assert ack["edge_strength"] == pytest.approx(33.0)

        server.send(protocol.CMD_SET_INFERENCE_SIZE, size=416)
        ack, _ = server.wait_for(
            lambda header: header.get("action") == protocol.CMD_SET_INFERENCE_SIZE, deadline=20.0
        )
        assert ack["inference_size"] == 416  # 运行时 imgsz 开关生效

        server.send(protocol.CMD_SET_BEV, enabled=True)
        ack, _ = server.wait_for(lambda header: header.get("action") == protocol.CMD_SET_BEV, deadline=20.0)
        assert ack["bev"] is True

        server.send("不存在的指令")
        error, _ = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_ERROR, deadline=20.0, description="未知指令错误"
        )
        assert "未知指令" in error["message"]

        status, _ = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_STATUS and bool(header.get("error")),
            deadline=30.0,
            description="视频源错误状态",
        )
        assert "视频源" in status["error"]
    finally:
        server.close()


def test_server_streams_inference_frames_and_bev(tmp_path: Path, fp32_model: Path):
    """真实视频源：持续收到 JPEG 推理画面，并按需收到 BEV 画面。"""
    video = _make_test_video(tmp_path / "synthetic.avi")
    if video is None:
        pytest.skip("无法用 OpenCV 生成测试视频（缺少编码器）")

    server = ServerProcess(source=video, model=fp32_model)
    try:
        server.connect()
        server.send(protocol.CMD_SET_BEV, enabled=True)

        frame, payload = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_FRAME and bool(header.get("status")),
            deadline=MESSAGE_DEADLINE,
            description="AI 推理画面",
        )
        assert payload.startswith(b"\xff\xd8"), "帧负载不是 JPEG 数据"
        status = frame["status"]
        assert status["engine"] == "VideoThread"
        assert status["inference_size"] == protocol.DEFAULT_INFERENCE_SIZE
        assert "fps" not in status, "移动端状态中不应包含帧率"
        assert status["frame_count"] >= 1

        from PIL import Image
        import io as _io

        with Image.open(_io.BytesIO(payload)) as image:
            assert image.size[0] > 0 and image.size[1] > 0
            assert image.format == "JPEG"

        bev, bev_payload = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_BEV, deadline=MESSAGE_DEADLINE, description="BEV 画面"
        )
        assert bev_payload.startswith(b"\xff\xd8")
        assert bev["seq"] >= frame["seq"]

        # 连续帧序号必须递增
        later, _ = server.wait_for(
            lambda header: header.get("type") == protocol.TYPE_FRAME and header.get("seq", 0) > frame["seq"],
            deadline=MESSAGE_DEADLINE,
            description="后续推理画面",
        )
        assert later["seq"] > frame["seq"]
    finally:
        server.close()
