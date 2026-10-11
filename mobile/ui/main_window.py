"""移动端主界面。

布局（与设计要求一一对应）：

* 画面中央/满屏：**AI 推理画面**（不再显示预处理画面，也不显示帧率）；
* 左上角：汉堡设置栏，内含切换摄像头、阈值设置、推理图片大小等功能；
* 右上角：``卸载推理`` 状态徽标（取代原先的帧率 / 稳定性指标）。
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

from PySide6 import QtCore, QtGui, QtWidgets
from mobile import protocol
from mobile.client.settings import MobileSettings
from mobile.client.transport import (
    STATE_CONNECTING,
    STATE_OFFLINE,
    FrameClient,
)
from mobile.ui.drawer import DRAWER_MAX_WIDTH, DRAWER_MIN_WIDTH, SettingsDrawer
from mobile.ui.overlay import TOP_BAR_HEIGHT, TopBar
from mobile.ui.video_view import VideoSurface

DRAWER_ANIMATION_MS = 220


class Scrim(QtWidgets.QWidget):
    """抽屉展开时的遮罩层，点击即可收起。"""

    clicked = QtCore.Signal()

    def __init__(self, parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)

    def paintEvent(self, event) -> None:  # noqa: D102 - Qt 回调
        painter = QtGui.QPainter(self)
        painter.fillRect(self.rect(), QtGui.QColor(0, 0, 0, 150))
        painter.end()

    def mousePressEvent(self, event) -> None:  # noqa: D102 - Qt 回调
        self.clicked.emit()


class MobileWindow(QtWidgets.QWidget):
    """移动端主窗口。"""

    def __init__(
        self,
        settings: MobileSettings,
        settings_path: Optional[Path] = None,
        client: Optional[FrameClient] = None,
        parent: Optional[QtWidgets.QWidget] = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("FastGuard 移动端")
        self.resize(430, 900)
        self._settings = settings.normalize()
        self._settings_path = Path(settings_path) if settings_path else MobileSettings.default_path()
        self._sync_sent = False
        self._has_frames = False

        self.surface = VideoSurface(self)
        self.surface.set_placeholder("等待推理画面", f"正在连接 {self._settings.host}:{self._settings.port}")

        self.top_bar = TopBar(self)
        self.drawer = SettingsDrawer(self._settings, self)
        self.scrim = Scrim(self)
        self.scrim.hide()

        self.client = client or FrameClient(self._settings.host, self._settings.port, self)
        self._wire_signals()

        self._drawer_open = False
        self._drawer_width = DRAWER_MIN_WIDTH
        self._animation = QtCore.QPropertyAnimation(self.drawer, b"geometry", self)
        self._animation.setDuration(DRAWER_ANIMATION_MS)
        self._animation.setEasingCurve(QtCore.QEasingCurve.OutCubic)
        self._animation.finished.connect(self._on_animation_finished)

        self.surface.set_bev_visible(self._settings.show_bev)

    # ------------------------------------------------------------------ 装配
    def _wire_signals(self) -> None:
        self.top_bar.settings_clicked.connect(self.toggle_drawer)
        self.scrim.clicked.connect(self.close_drawer)
        self.drawer.close_requested.connect(self.close_drawer)

        self.drawer.camera_changed.connect(self._on_camera_changed)
        self.drawer.thresholds_changed.connect(self._on_thresholds_changed)
        self.drawer.inference_size_changed.connect(self._on_inference_size_changed)
        self.drawer.bev_toggled.connect(self._on_bev_toggled)
        self.drawer.endpoint_changed.connect(self._on_endpoint_changed)
        self.drawer.reset_requested.connect(self._on_reset_requested)

        self.client.frame_received.connect(self._on_frame)
        self.client.link_state_changed.connect(self._on_link_state)
        self.client.status_received.connect(self._on_status)
        self.client.error_received.connect(self._on_error)
        self.client.command_result.connect(self._on_command_result)

    def start(self) -> None:
        """启动后台接收线程。"""
        if not self.client.isRunning():
            self.client.start()

    @property
    def settings(self) -> MobileSettings:
        """当前生效的移动端配置。"""
        return self._settings

    # ------------------------------------------------------------------ 抽屉
    def resizeEvent(self, event) -> None:  # noqa: D102 - Qt 回调
        super().resizeEvent(event)
        width, height = self.width(), self.height()
        self.surface.setGeometry(0, 0, width, height)
        self.top_bar.setGeometry(0, 0, width, TOP_BAR_HEIGHT)
        self.scrim.setGeometry(0, 0, width, height)

        self._drawer_width = max(DRAWER_MIN_WIDTH, min(DRAWER_MAX_WIDTH, int(width * 0.86)))
        hidden_x = -self._drawer_width
        self.drawer.setGeometry(hidden_x if not self._drawer_open else 0, 0, self._drawer_width, height)
        self.top_bar.raise_()

    def toggle_drawer(self) -> None:
        self.close_drawer() if self._drawer_open else self.open_drawer()

    def open_drawer(self) -> None:
        self._drawer_open = True
        self.scrim.setGeometry(self.rect())
        self.scrim.show()
        self.scrim.raise_()
        self.drawer.raise_()
        self.top_bar.raise_()
        self._animate_drawer(0)

    def close_drawer(self) -> None:
        if not self._drawer_open:
            return
        self._drawer_open = False
        self._animate_drawer(-self._drawer_width)

    def _animate_drawer(self, target_x: int) -> None:
        self._animation.stop()
        self._animation.setStartValue(self.drawer.geometry())
        self._animation.setEndValue(
            QtCore.QRect(target_x, 0, self._drawer_width, self.height())
        )
        self._animation.start()

    def _on_animation_finished(self) -> None:
        if not self._drawer_open:
            self.scrim.hide()

    def keyPressEvent(self, event) -> None:  # noqa: D102 - Qt 回调
        if event.key() == QtCore.Qt.Key_Escape and self._drawer_open:
            self.close_drawer()
            return
        super().keyPressEvent(event)

    # ------------------------------------------------------------------ 设置回调
    def _persist(self) -> None:
        try:
            self._settings.save(self._settings_path)
        except OSError:
            pass

    def _on_camera_changed(self, index: int) -> None:
        self._settings.camera_index = int(index)
        self._persist()
        self._has_frames = False
        self.surface.set_placeholder("正在切换摄像头…", f"服务端正在重新打开摄像头 {index}")
        self.client.send_command(protocol.CMD_SET_SOURCE, index=int(index))
        self.drawer.set_status_text(f"已切换到摄像头 {index}，服务端正在重新打开视频源…")

    def _on_thresholds_changed(self, weak_conf: float, edge_strength: float) -> None:
        self._settings.weak_conf = float(weak_conf)
        self._settings.edge_strength = float(edge_strength)
        self._persist()
        self.client.send_command(
            protocol.CMD_SET_THRESHOLDS, weak_conf=float(weak_conf), edge_strength=float(edge_strength)
        )
        self.drawer.set_status_text(f"阈值已下发：{weak_conf:.2f} / {edge_strength:.1f}")

    def _on_inference_size_changed(self, size: int) -> None:
        self._settings.inference_size = int(size)
        self._persist()
        self.client.send_command(protocol.CMD_SET_INFERENCE_SIZE, size=int(size))
        self.drawer.set_status_text(f"推理图片大小已下发：{size} px")

    def _on_bev_toggled(self, enabled: bool) -> None:
        self._settings.show_bev = bool(enabled)
        self._persist()
        self.surface.set_bev_visible(bool(enabled))
        self.client.send_command(protocol.CMD_SET_BEV, enabled=bool(enabled))
        self.drawer.set_status_text("已开启 BEV 俯视图叠加" if enabled else "已关闭 BEV 俯视图叠加")

    def _on_endpoint_changed(self, host: str, port: int) -> None:
        self._settings.host = host
        self._settings.port = int(port)
        self._persist()
        self.client.set_endpoint(host, int(port))
        self._sync_sent = False
        self.surface.set_placeholder("正在连接推理服务", f"{host}:{port}")
        self.drawer.set_status_text(f"正在连接 {host}:{port} …")

    def _on_reset_requested(self) -> None:
        defaults = MobileSettings()
        defaults.host = self._settings.host
        defaults.port = self._settings.port
        defaults.autostart_backend = self._settings.autostart_backend
        self._settings = defaults.normalize()
        self.drawer.apply_settings(self._settings)
        self.surface.set_bev_visible(self._settings.show_bev)
        self.client.send_command(
            protocol.CMD_SET_THRESHOLDS,
            weak_conf=self._settings.weak_conf,
            edge_strength=self._settings.edge_strength,
        )
        self.client.send_command(protocol.CMD_SET_INFERENCE_SIZE, size=self._settings.inference_size)
        self.client.send_command(protocol.CMD_SET_BEV, enabled=self._settings.show_bev)
        self._persist()
        self.drawer.set_status_text("已恢复默认设置")

    # ------------------------------------------------------------------ 服务端回调
    def _on_link_state(self, state: str, detail: str) -> None:
        self.top_bar.set_link_state(state, detail)
        if state in (STATE_OFFLINE, STATE_CONNECTING):
            if state == STATE_OFFLINE:
                self.surface.set_placeholder("推理服务未连接", detail or "请检查服务地址后重试")
            else:
                self.surface.set_placeholder("正在连接推理服务", detail)
        if state == STATE_OFFLINE:
            self.drawer.set_status_text(detail or "推理服务已断开")

    def _on_status(self, status: Dict[str, Any]) -> None:
        if not self._sync_sent:
            self._sync_sent = True
            self.client.send_command(protocol.CMD_SET_BEV, enabled=bool(self._settings.show_bev))
        self.drawer.apply_server_state(status)
        parts = []
        state = str(status.get("state", ""))
        state_text = {
            "running": "运行中",
            "scanning": "等待画面",
            "idle": "待机",
            "stopped": "已停止",
        }.get(state, state or "未知")
        parts.append(f"服务端 {state_text}")
        if status.get("source") is not None:
            parts.append(f"摄像头 {status['source']}")
        if status.get("inference_size"):
            parts.append(f"{status['inference_size']}px")
        if status.get("model"):
            parts.append(str(status["model"]))
        error = status.get("error")
        text = " · ".join(parts)
        self.drawer.set_status_text(f"{text}｜{error}" if error else text)
        if error and not self._has_frames:
            self.surface.set_placeholder("暂无推理画面", str(error))

    def _on_frame(self, image, bev) -> None:
        self._has_frames = True
        self.surface.set_frame(image, bev)

    def _on_error(self, message: str) -> None:
        self.drawer.set_status_text(message)

    def _on_command_result(self, action: str, ok: bool, detail: str = "") -> None:
        if ok:
            return
        self.drawer.set_status_text(detail or f"指令 {action} 执行失败")

    # ------------------------------------------------------------------ 关闭
    def closeEvent(self, event) -> None:  # noqa: D102 - Qt 回调
        self._persist()
        self.client.stop()
        super().closeEvent(event)
