"""FastGuard 移动端界面（Qt6 / PySide6）回归测试。

覆盖范围：
* 移动端 ↔ 推理服务 协议编解码（含分片到达、错误魔数）；
* 移动端本地配置的校验与持久化；
* 界面结构：满屏 AI 推理画面、左上角汉堡设置栏、右上角"卸载推理"徽标，
  并断言"预处理画面"与"帧率"确实被省略；
* 汉堡设置栏功能：切换摄像头、阈值设置、推理图片大小设置的下发；
* 客户端接收线程能把服务端 JPEG 消息还原为 QImage，并能回传控制指令。

注意：本文件只允许导入 **PySide6（Qt6）**；PyQt5 侧（``mobile.backend``、
``core.video_thread``）的测试在 ``tests/test_mobile_backend.py`` 中通过
独立子进程验证，避免同一进程加载两套 Qt 绑定。

运行方式：
    pytest tests/test_mobile_ui.py -v
"""

from __future__ import annotations

import io
import os
import socket
import sys
import threading
import time
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# 无显示环境下也能构建/绘制界面。
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from mobile import protocol  # noqa: E402
from mobile.client.settings import MobileSettings  # noqa: E402

pytest.importorskip("PySide6", reason="移动端界面依赖 Qt6 / PySide6")

from PySide6 import QtCore, QtGui, QtWidgets  # noqa: E402

from mobile.client.transport import FrameClient, STATE_CONNECTING, STATE_OFFLINE, STATE_ONLINE  # noqa: E402
from mobile.ui.drawer import SettingsDrawer  # noqa: E402
from mobile.ui.main_window import MobileWindow  # noqa: E402
from mobile.ui.overlay import TOP_BAR_HEIGHT, OffloadBadge, TopBar  # noqa: E402
from mobile.ui.video_view import VideoSurface  # noqa: E402

#: 设计要求：这些指标/画面不应出现在移动端界面上。
FORBIDDEN_TEXTS = ("帧率", "FPS", "fps", "预处理")


# ====================================================================== 工具
@pytest.fixture(scope="session")
def qt_app():
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    yield app


def wait_until(app, predicate, timeout: float = 6.0) -> bool:
    """在事件循环中等待条件成立（避免测试挂死）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        app.processEvents()
        if predicate():
            return True
        time.sleep(0.02)
    return False


def collect_texts(widget: QtWidgets.QWidget) -> list:
    texts = []
    for child in widget.findChildren(QtWidgets.QWidget):
        for getter in ("text", "placeholderText", "toolTip"):
            method = getattr(child, getter, None)
            if callable(method):
                try:
                    value = method()
                except TypeError:  # pragma: no cover - 个别控件签名不同
                    continue
                if isinstance(value, str) and value:
                    texts.append(value)
    return texts


def make_jpeg(width: int = 320, height: int = 240) -> bytes:
    image = QtGui.QImage(width, height, QtGui.QImage.Format_RGB32)
    image.fill(QtGui.QColor(30, 120, 220))
    buffer = QtCore.QBuffer()
    buffer.open(QtCore.QIODevice.WriteOnly)
    assert image.save(buffer, "JPG", 80)
    return bytes(buffer.data())


class RecordingClient(FrameClient):
    """不联网的客户端，仅记录下发的指令。"""

    def __init__(self, host: str = protocol.DEFAULT_HOST, port: int = protocol.DEFAULT_PORT) -> None:
        super().__init__(host, port, None)
        self.commands: list = []

    def send_command(self, action: str, **params) -> None:  # noqa: D102 - 覆盖以记录
        self.commands.append({"action": action, **params})

    def stop(self, timeout_ms: int = 0) -> None:  # noqa: D102 - 线程未启动
        return

    def commands_for(self, action: str) -> list:
        return [command for command in self.commands if command["action"] == action]


class FakeFrameServer:
    """一次性 TCP 服务：连接后推送一帧 + 一条状态，然后读取客户端指令。"""

    def __init__(self) -> None:
        self.received: list = []
        self.port = 0
        self._socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._socket.bind(("127.0.0.1", 0))
        self._socket.listen(1)
        self.port = self._socket.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self) -> None:
        try:
            connection, _ = self._socket.accept()
        except OSError:  # pragma: no cover - 测试收尾时关闭
            return
        with connection:
            connection.sendall(
                protocol.encode_message(
                    {"type": protocol.TYPE_STATUS, "state": "running", "source": 0, "inference_size": 320}
                )
            )
            connection.sendall(
                protocol.encode_message(
                    {"type": protocol.TYPE_FRAME, "seq": 1, "status": {"state": "running"}}, make_jpeg()
                )
            )
            file = connection.makefile("rb")
            try:
                while True:
                    header, _payload = protocol.read_message(file)
                    self.received.append(header)
            except (ConnectionError, OSError, protocol.ProtocolError):
                pass

    def close(self) -> None:
        try:
            self._socket.close()
        except OSError:  # pragma: no cover
            pass


# ====================================================================== 协议
def test_protocol_roundtrip():
    payload = b"\xff\xd8jpeg-bytes"
    header = {"type": protocol.TYPE_FRAME, "seq": 7, "status": {"state": "running"}}
    stream = io.BytesIO(protocol.encode_message(header, payload))
    decoded_header, decoded_payload = protocol.read_message(stream)
    assert decoded_header["type"] == protocol.TYPE_FRAME
    assert decoded_header["seq"] == 7
    assert decoded_header["v"] == protocol.PROTOCOL_VERSION
    assert decoded_payload == payload


def test_protocol_framer_handles_fragmentation():
    message = protocol.encode_message({"type": protocol.TYPE_CMD, "action": protocol.CMD_PING})
    framer = protocol.BytesFramer()
    parsed = []
    for index in range(len(message)):
        parsed.extend(framer.feed(message[index:index + 1]))
    assert len(parsed) == 1
    assert parsed[0][0]["action"] == protocol.CMD_PING


def test_protocol_framer_rejects_bad_magic():
    framer = protocol.BytesFramer()
    with pytest.raises(protocol.ProtocolError):
        framer.feed(b"XXXX" + b"\x00" * 16)


def test_protocol_command_and_error_helpers():
    header, _ = protocol.read_message(io.BytesIO(protocol.make_command(protocol.CMD_SET_SOURCE, index=2)))
    assert header["type"] == protocol.TYPE_CMD
    assert header["index"] == 2

    header, _ = protocol.read_message(io.BytesIO(protocol.make_error("boom", protocol.CMD_PING)))
    assert header["type"] == protocol.TYPE_ERROR
    assert header["message"] == "boom"


# ====================================================================== 配置
def test_settings_defaults_and_validation():
    settings = MobileSettings.from_dict(
        {
            "host": "   ",
            "port": 99999,
            "camera_index": -3,
            "weak_conf": 5.0,
            "edge_strength": 0.0,
            "inference_size": 333,
            "show_bev": 1,
            "unknown_key": "ignored",
        }
    )
    assert settings.host == protocol.DEFAULT_HOST
    assert settings.port == 65535
    assert settings.camera_index == 0
    assert settings.weak_conf == 0.95
    assert settings.edge_strength == 1.0
    assert settings.inference_size == 320
    assert settings.show_bev is True


def test_settings_roundtrip(tmp_path: Path):
    path = tmp_path / "mobile_settings.json"
    original = MobileSettings(camera_index=1, inference_size=512, weak_conf=0.5, edge_strength=30.0, show_bev=True)
    original.save(path)
    loaded = MobileSettings.load(path)
    assert loaded.to_dict() == original.normalize().to_dict()


def test_settings_load_missing_or_broken_file(tmp_path: Path):
    assert MobileSettings.load(tmp_path / "missing.json") == MobileSettings().normalize()
    broken = tmp_path / "broken.json"
    broken.write_text("{not json", encoding="utf-8")
    assert MobileSettings.load(broken) == MobileSettings().normalize()


# ====================================================================== 界面结构
def test_main_window_structure_and_omitted_views(qt_app, tmp_path: Path):
    client = RecordingClient()
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=client)
    window.resize(430, 900)
    window.show()
    qt_app.processEvents()

    assert isinstance(window.surface, VideoSurface)
    assert isinstance(window.top_bar, TopBar)
    assert isinstance(window.drawer, SettingsDrawer)

    badge = window.top_bar.badge
    assert isinstance(badge, OffloadBadge)
    assert badge.title_text() == "卸载推理"
    assert badge.state() == STATE_CONNECTING
    assert badge.state_text() == "连接中"

    # 服务端连接状态驱动徽标文案（这是"卸载推理"取代帧率/稳定性的唯一指标）
    window.client.link_state_changed.emit(STATE_ONLINE, "推理运算已在服务端完成")
    assert badge.state_text() == "运行中"
    window.client.link_state_changed.emit(STATE_OFFLINE, "推理服务已断开")
    assert badge.state_text() == "已断开"

    # 左上角是汉堡按钮，右上角是"卸载推理"徽标。
    hamburger_center = window.top_bar.hamburger.mapTo(window, window.top_bar.hamburger.rect().center())
    badge_center = badge.mapTo(window, badge.rect().center())
    assert hamburger_center.x() < window.width() // 2
    assert badge_center.x() > window.width() // 2
    assert hamburger_center.y() < TOP_BAR_HEIGHT
    assert badge_center.y() < TOP_BAR_HEIGHT
    assert window.top_bar.hamburger.width() >= 48  # 触控友好

    # 设计要求：不再显示预处理画面与帧率。
    texts = " ".join(collect_texts(window))
    for forbidden in FORBIDDEN_TEXTS:
        assert forbidden not in texts

    window.close()


def test_drawer_exposes_required_controls(qt_app, tmp_path: Path):
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=RecordingClient())
    drawer = window.drawer

    assert drawer.camera_control.value() == 0
    assert set(drawer.camera_control.options()) == set(protocol.CAMERA_CHOICES)
    assert drawer.inference_size() == protocol.DEFAULT_INFERENCE_SIZE
    assert set(drawer.size_control.options()) == set(protocol.INFERENCE_SIZE_CHOICES)
    assert drawer.weak_slider.value() == 38
    assert drawer.edge_slider.value() == 280
    assert drawer.weak_value_label.text() == "0.38"
    assert drawer.edge_value_label.text() == "28.0"
    assert drawer.bev_enabled() is False
    assert drawer.host_edit.text() == protocol.DEFAULT_HOST
    assert drawer.port_edit.text() == str(protocol.DEFAULT_PORT)
    window.close()


def test_drawer_locks_inference_size_for_fixed_input_model(qt_app, tmp_path: Path):
    """INT8 固定输入模型：只允许其原生尺寸，避免下发无效尺寸。"""
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=RecordingClient())
    drawer = window.drawer
    drawer.apply_server_state({"inference_size": 320, "fixed_inference_size": 320})

    buttons = drawer.size_control._buttons
    assert buttons[320].isEnabled() is True
    assert buttons[416].isEnabled() is False
    assert "320" in drawer.size_hint.text()

    drawer.apply_server_state({"inference_size": 416, "fixed_inference_size": None})
    assert all(button.isEnabled() for button in buttons.values())
    assert drawer.size_control.value() == 416
    window.close()


def test_top_bar_animation_and_drawer_toggle(qt_app, tmp_path: Path):
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=RecordingClient())
    window.resize(440, 900)
    window.show()
    qt_app.processEvents()

    assert window.scrim.isHidden()
    window.top_bar.hamburger.click()
    assert wait_until(qt_app, lambda: window.drawer.x() == 0, timeout=3.0), "设置栏未展开"
    assert not window.scrim.isHidden()

    window.scrim.clicked.emit()
    assert wait_until(qt_app, lambda: window.drawer.x() <= -window.drawer.width(), timeout=3.0), "设置栏未收起"
    window.close()


# ====================================================================== 交互
def test_drawer_commands_are_dispatched(qt_app, tmp_path: Path):
    client = RecordingClient()
    settings = MobileSettings(show_bev=False)
    window = MobileWindow(settings, settings_path=tmp_path / "s.json", client=client)
    drawer = window.drawer

    drawer.camera_control.set_value(1, emit=True)
    assert client.commands_for(protocol.CMD_SET_SOURCE)[-1]["index"] == 1
    assert window.settings.camera_index == 1

    drawer.size_control.set_value(416, emit=True)
    assert client.commands_for(protocol.CMD_SET_INFERENCE_SIZE)[-1]["size"] == 416
    assert window.settings.inference_size == 416

    drawer.bev_checkbox.setChecked(True)
    assert client.commands_for(protocol.CMD_SET_BEV)[-1]["enabled"] is True
    assert window.surface.bev_visible() is True

    drawer.weak_slider.setValue(50)
    drawer.edge_slider.setValue(300)
    from PySide6.QtTest import QTest

    QTest.qWait(320)
    threshold_commands = client.commands_for(protocol.CMD_SET_THRESHOLDS)
    assert threshold_commands, "阈值指令未下发"
    assert threshold_commands[-1]["weak_conf"] == pytest.approx(0.50)
    assert threshold_commands[-1]["edge_strength"] == pytest.approx(30.0)

    drawer.host_edit.setText("192.168.1.30")
    drawer.port_edit.setText("9000")
    drawer.reconnect_button.click()
    assert client.endpoint() == ("192.168.1.30", 9000)
    assert window.settings.host == "192.168.1.30"

    # 配置应写入磁盘
    saved = MobileSettings.load(tmp_path / "s.json")
    assert saved.camera_index == 1
    assert saved.inference_size == 416
    assert saved.show_bev is True
    window.close()


def test_drawer_syncs_from_server_status(qt_app, tmp_path: Path):
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=RecordingClient())
    window.drawer.apply_server_state(
        {"source": 2, "inference_size": 640, "weak_conf": 0.6, "edge_strength": 40.0, "bev": True}
    )
    drawer = window.drawer
    assert drawer.camera_index() == 2
    assert drawer.inference_size() == 640
    assert drawer.weak_value_label.text() == "0.60"
    assert drawer.edge_value_label.text() == "40.0"
    assert drawer.bev_enabled() is True
    window.close()


def test_offload_badge_states(qt_app):
    badge = OffloadBadge()
    badge.set_state(STATE_ONLINE, "推理运算已在服务端完成")
    assert badge.state_text() == "运行中"
    badge.set_state("stalled")
    assert badge.state_text() == "画面停滞"
    badge.set_state(STATE_OFFLINE)
    assert badge.state_text() == "已断开"
    assert badge.title_text() == "卸载推理"


def test_command_failure_reason_is_surfaced(qt_app, tmp_path: Path):
    window = MobileWindow(MobileSettings(), settings_path=tmp_path / "s.json", client=RecordingClient())
    window.client.command_result.emit(protocol.CMD_SET_INFERENCE_SIZE, False, "当前 INT8 模型输入固定为 320")
    assert "INT8 模型输入固定为 320" in window.drawer.status_label.text()
    window.client.command_result.emit(protocol.CMD_SET_BEV, True, "")
    assert "INT8 模型输入固定为 320" in window.drawer.status_label.text()
    window.close()


def test_model_info_detects_fixed_input_model(tmp_path: Path):
    """INT8/OpenVINO 导出目录存在时，应识别为固定输入模型。"""
    from mobile.backend.model_info import detect_fixed_inference_size, int8_model_dir

    plain = tmp_path / "yolo11n.pt"
    plain.write_bytes(b"")
    assert int8_model_dir(str(plain)) is None
    assert detect_fixed_inference_size(str(plain)) is None

    model_dir = tmp_path / "yolo11n_int8_openvino_model"
    model_dir.mkdir()
    (model_dir / "metadata.yaml").write_text("task: detect\nimgsz:\n- 416\n- 416\n", encoding="utf-8")
    assert detect_fixed_inference_size(str(plain)) == 416

    (model_dir / "metadata.yaml").write_text("task: detect\n", encoding="utf-8")
    assert detect_fixed_inference_size(str(plain)) == 320  # 读不到尺寸时回退默认值

    # 仓库中的真实权重也应被正确识别（存在 INT8 导出目录）
    real = PROJECT_ROOT / "assets" / "weights" / "yolo11n.pt"
    if real.exists() and (PROJECT_ROOT / "assets" / "weights" / "yolo11n_int8_openvino_model").is_dir():
        assert detect_fixed_inference_size(str(real)) == protocol.DEFAULT_INFERENCE_SIZE


def test_validate_inference_size_rules():
    """回归用例：固定输入模型拒绝其它 imgsz，可变尺寸模型正常放行。

    （INT8/OpenVINO 导出固定输入，运行时强行改 imgsz 会直接中断推理。）
    """
    from mobile.backend.model_info import validate_inference_size

    accepted, applied, reason = validate_inference_size(320, 320)
    assert accepted is True
    assert applied == 320
    assert reason is None

    accepted, applied, reason = validate_inference_size(512, 320)
    assert accepted is False
    assert applied == 320
    assert reason and "固定" in reason and "512" in reason

    accepted, applied, reason = validate_inference_size(512, None)
    assert accepted is True
    assert applied == 512
    assert reason is None

    accepted, applied, reason = validate_inference_size("不是数字", None)
    assert accepted is False
    assert applied == 320
    assert reason


def test_video_surface_renders_frame_and_bev(qt_app):
    surface = VideoSurface()
    surface.resize(320, 640)
    surface.set_bev_visible(True)
    inference = QtGui.QImage(640, 480, QtGui.QImage.Format_RGB32)
    inference.fill(QtGui.QColor(10, 200, 120))
    bev = QtGui.QImage(300, 400, QtGui.QImage.Format_RGB32)
    bev.fill(QtGui.QColor(60, 60, 60))

    surface.set_frame(inference, bev)
    qt_app.processEvents()
    assert surface.frame_size() == QtCore.QSize(640, 480)
    pixmap = surface.grab()
    assert not pixmap.isNull()

    surface.set_placeholder("推理服务未连接", "请检查服务地址")
    assert surface.frame_size().isEmpty()


# ====================================================================== 客户端
def test_frame_client_receives_frames_and_sends_commands(qt_app):
    server = FakeFrameServer()
    client = FrameClient("127.0.0.1", server.port)
    frames: list = []
    statuses: list = []
    states: list = []
    client.frame_received.connect(lambda image, bev: frames.append((image, bev)))
    client.status_received.connect(statuses.append)
    client.link_state_changed.connect(lambda state, detail: states.append(state))
    client.start()
    try:
        assert wait_until(qt_app, lambda: bool(frames), timeout=8.0), "未收到推理画面"
        image, bev = frames[0]
        assert image.size() == QtCore.QSize(320, 240)
        assert bev is None
        assert wait_until(qt_app, lambda: bool(statuses), timeout=3.0), "未收到状态消息"
        assert statuses[0]["inference_size"] == 320
        assert STATE_ONLINE in states

        client.send_command(protocol.CMD_SET_INFERENCE_SIZE, size=512)
        assert wait_until(qt_app, lambda: bool(server.received), timeout=5.0), "控制指令未送达"
        assert server.received[0]["action"] == protocol.CMD_SET_INFERENCE_SIZE
        assert server.received[0]["size"] == 512
    finally:
        client.stop()
        server.close()
    assert wait_until(qt_app, lambda: STATE_OFFLINE in states, timeout=3.0), "断开后未上报离线状态"


def test_frame_client_endpoint_switch(qt_app):
    client = FrameClient("127.0.0.1", 8765)
    client.set_endpoint("10.0.0.5", 9999)
    assert client.endpoint() == ("10.0.0.5", 9999)


def test_backend_command_builder_includes_mobile_settings():
    from mobile.client.backend_launcher import build_backend_command

    settings = MobileSettings(camera_index=1, inference_size=416, weak_conf=0.5, edge_strength=30.0, port=8899)
    command = build_backend_command(settings, host="0.0.0.0")
    assert "mobile.backend.frame_server" in command
    assert command[command.index("--port") + 1] == "8899"
    assert command[command.index("--source") + 1] == "1"
    assert command[command.index("--inference-size") + 1] == "416"
    assert command[command.index("--weak-conf") + 1] == "0.5"
    assert command[command.index("--edge-strength") + 1] == "30.0"
