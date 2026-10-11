"""左上角汉堡设置栏（抽屉）：切换摄像头、阈值设置、推理图片大小等。"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Sequence, Tuple

from PySide6 import QtCore, QtWidgets

from mobile import platform_info, protocol
from mobile.client.settings import EDGE_STRENGTH_RANGE, WEAK_CONF_RANGE, MobileSettings
from mobile.ui import theme

DRAWER_MIN_WIDTH = 288
DRAWER_MAX_WIDTH = 380

#: 阈值滑块的内部刻度（整数）与浮点值的换算。
_WEAK_CONF_SCALE = 100
_EDGE_SCALE = 10


class SegmentedControl(QtWidgets.QWidget):
    """一组互斥按钮，用触摸友好的方式单选。"""

    value_changed = QtCore.Signal(object)

    def __init__(
        self,
        options: Sequence[Tuple[Any, str]],
        columns: int = 0,
        parent: Optional[QtWidgets.QWidget] = None,
    ) -> None:
        super().__init__(parent)
        self._buttons: Dict[Any, QtWidgets.QPushButton] = {}
        self._group = QtWidgets.QButtonGroup(self)
        self._group.setExclusive(True)
        self._value: Any = options[0][0] if options else None

        columns = columns or len(options)
        grid = QtWidgets.QGridLayout(self)
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setSpacing(8)
        for index, (value, label) in enumerate(options):
            button = QtWidgets.QPushButton(label)
            button.setObjectName("segmentButton")
            button.setCheckable(True)
            button.setCursor(QtCore.Qt.PointingHandCursor)
            button.setMinimumHeight(44)
            button.clicked.connect(lambda _checked=False, v=value: self._on_clicked(v))
            grid.addWidget(button, index // columns, index % columns)
            self._buttons[value] = button
            self._group.addButton(button)
        if options:
            self._buttons[self._value].setChecked(True)

    def _on_clicked(self, value: Any) -> None:
        if value == self._value:
            return
        self._value = value
        self.value_changed.emit(value)

    def value(self) -> Any:
        return self._value

    def options(self) -> List[Any]:
        """全部候选项（按界面顺序）。"""
        return list(self._buttons.keys())

    def set_enabled_values(self, allowed: Optional[Sequence[Any]]) -> None:
        """只保留 ``allowed`` 中的可选项；``None`` 表示全部可用。"""
        for value, button in self._buttons.items():
            button.setEnabled(allowed is None or value in allowed)

    def set_value(self, value: Any, emit: bool = False) -> None:
        if value not in self._buttons:
            return
        changed = value != self._value
        self._value = value
        self._buttons[value].setChecked(True)
        if emit and changed:
            self.value_changed.emit(value)


class DrawerSection(QtWidgets.QFrame):
    """带标题与说明的设置卡片。"""

    def __init__(self, title: str, hint: str = "", parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("drawerSection")
        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(14, 14, 14, 16)
        outer.setSpacing(10)

        title_label = QtWidgets.QLabel(title)
        title_label.setObjectName("sectionTitle")
        outer.addWidget(title_label)
        if hint:
            hint_label = QtWidgets.QLabel(hint)
            hint_label.setObjectName("sectionHint")
            hint_label.setWordWrap(True)
            outer.addWidget(hint_label)

        self.body = QtWidgets.QVBoxLayout()
        self.body.setSpacing(10)
        outer.addLayout(self.body)


class SettingsDrawer(QtWidgets.QFrame):
    """汉堡设置栏本体。"""

    camera_changed = QtCore.Signal(int)
    thresholds_changed = QtCore.Signal(float, float)
    inference_size_changed = QtCore.Signal(int)
    bev_toggled = QtCore.Signal(bool)
    endpoint_changed = QtCore.Signal(str, int)
    reset_requested = QtCore.Signal()
    close_requested = QtCore.Signal()

    def __init__(self, settings: MobileSettings, parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("settingsDrawer")
        self.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        self._loading = True
        self._settings = settings

        outer = QtWidgets.QVBoxLayout(self)
        outer.setContentsMargins(16, 16, 16, 16)
        outer.setSpacing(12)

        outer.addLayout(self._build_header())
        self.scroll = QtWidgets.QScrollArea(self)
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        content = QtWidgets.QWidget()
        content_layout = QtWidgets.QVBoxLayout(content)
        content_layout.setContentsMargins(0, 0, 6, 0)
        content_layout.setSpacing(14)

        content_layout.addWidget(self._build_camera_section())
        content_layout.addWidget(self._build_threshold_section())
        content_layout.addWidget(self._build_inference_size_section())
        content_layout.addWidget(self._build_display_section())
        content_layout.addWidget(self._build_service_section())
        content_layout.addWidget(self._build_about_section())
        content_layout.addStretch(1)
        self.scroll.setWidget(content)
        outer.addWidget(self.scroll, 1)

        self._threshold_timer = QtCore.QTimer(self)
        self._threshold_timer.setSingleShot(True)
        self._threshold_timer.setInterval(220)
        self._threshold_timer.timeout.connect(self._emit_thresholds)

        self.apply_settings(settings)
        self._loading = False

    # ------------------------------------------------------------------ 构建
    def _build_header(self) -> QtWidgets.QHBoxLayout:
        row = QtWidgets.QHBoxLayout()
        row.setSpacing(8)
        title = QtWidgets.QLabel("设置")
        title.setStyleSheet(theme.font_style(20, 800, theme.TEXT))
        close = QtWidgets.QPushButton("✕")
        close.setObjectName("ghostButton")
        close.setFixedSize(theme.TOUCH_TARGET, theme.TOUCH_TARGET)
        close.setCursor(QtCore.Qt.PointingHandCursor)
        close.setToolTip("收起设置栏")
        close.clicked.connect(self.close_requested.emit)
        row.addWidget(title)
        row.addStretch(1)
        row.addWidget(close)
        return row

    def _build_camera_section(self) -> DrawerSection:
        section = DrawerSection(
            "切换摄像头",
            "手机端：0 = 后置主摄，1 = 前置；桌面端为设备序号。切换后服务端会重新打开视频源。",
        )
        options = [(index, str(index)) for index in protocol.CAMERA_CHOICES]
        self.camera_control = SegmentedControl(options, columns=4)
        self.camera_control.value_changed.connect(self._on_camera_changed)
        section.body.addWidget(self.camera_control)
        self.camera_hint = QtWidgets.QLabel("")
        self.camera_hint.setObjectName("sectionHint")
        section.body.addWidget(self.camera_hint)
        return section

    def _build_threshold_section(self) -> DrawerSection:
        section = DrawerSection("阈值设置", "低置信度阈值用于过滤弱目标，边缘强度阈值用于抑制静态纹理误报。")

        weak_row, self.weak_value_label, self.weak_slider = self._build_slider(
            "低置信度阈值",
            int(WEAK_CONF_RANGE[0] * _WEAK_CONF_SCALE),
            int(WEAK_CONF_RANGE[1] * _WEAK_CONF_SCALE),
            1,
        )
        edge_row, self.edge_value_label, self.edge_slider = self._build_slider(
            "边缘强度阈值",
            int(EDGE_STRENGTH_RANGE[0] * _EDGE_SCALE),
            int(EDGE_STRENGTH_RANGE[1] * _EDGE_SCALE),
            1,
        )
        section.body.addLayout(weak_row)
        section.body.addLayout(edge_row)
        self.weak_slider.valueChanged.connect(self._on_threshold_moved)
        self.edge_slider.valueChanged.connect(self._on_threshold_moved)
        return section

    def _build_slider(
        self, title: str, minimum: int, maximum: int, step: int
    ) -> Tuple[QtWidgets.QVBoxLayout, QtWidgets.QLabel, QtWidgets.QSlider]:
        column = QtWidgets.QVBoxLayout()
        column.setSpacing(6)
        header = QtWidgets.QHBoxLayout()
        label = QtWidgets.QLabel(title)
        label.setStyleSheet(theme.font_style(14, 600, theme.TEXT))
        value_label = QtWidgets.QLabel("0")
        value_label.setObjectName("valueLabel")
        header.addWidget(label)
        header.addStretch(1)
        header.addWidget(value_label)

        slider = QtWidgets.QSlider(QtCore.Qt.Horizontal)
        slider.setRange(minimum, maximum)
        slider.setSingleStep(step)
        slider.setPageStep(step * 5)
        column.addLayout(header)
        column.addWidget(slider)
        return column, value_label, slider

    def _build_inference_size_section(self) -> DrawerSection:
        section = DrawerSection(
            "推理图片大小",
            "对应 YOLO 的 imgsz：数值越小推理越快，越大对小目标越友好。",
        )
        options = [(size, f"{size} px") for size in protocol.INFERENCE_SIZE_CHOICES]
        self.size_control = SegmentedControl(options, columns=2)
        self.size_control.value_changed.connect(self._on_size_changed)
        section.body.addWidget(self.size_control)
        self.size_hint = QtWidgets.QLabel("")
        self.size_hint.setObjectName("sectionHint")
        self.size_hint.setWordWrap(True)
        section.body.addWidget(self.size_hint)
        self._fixed_inference_size: Optional[int] = None
        self._refresh_size_hint()
        return section

    def _build_display_section(self) -> DrawerSection:
        section = DrawerSection("显示", "移动端仅显示 AI 推理画面；可叠加 IPM 俯视图（BEV）作为画中画。")
        self.bev_checkbox = QtWidgets.QCheckBox("叠加 BEV 俯视图")
        self.bev_checkbox.setCursor(QtCore.Qt.PointingHandCursor)
        self.bev_checkbox.toggled.connect(self._on_bev_toggled)
        section.body.addWidget(self.bev_checkbox)
        return section

    def _build_service_section(self) -> DrawerSection:
        section = DrawerSection("推理服务", "填写运行 FastGuard 推理服务的地址（车机 / PC）。")
        endpoint_row = QtWidgets.QHBoxLayout()
        endpoint_row.setSpacing(8)
        self.host_edit = QtWidgets.QLineEdit()
        self.host_edit.setPlaceholderText("主机地址")
        self.host_edit.setClearButtonEnabled(True)
        self.port_edit = QtWidgets.QLineEdit()
        self.port_edit.setPlaceholderText("端口")
        self.port_edit.setFixedWidth(92)
        endpoint_row.addWidget(self.host_edit, 1)
        endpoint_row.addWidget(self.port_edit)
        section.body.addLayout(endpoint_row)

        self.reconnect_button = QtWidgets.QPushButton("重新连接")
        self.reconnect_button.setObjectName("primaryButton")
        self.reconnect_button.setCursor(QtCore.Qt.PointingHandCursor)
        self.reconnect_button.clicked.connect(self._on_endpoint_submitted)
        section.body.addWidget(self.reconnect_button)

        self.status_label = QtWidgets.QLabel("尚未连接")
        self.status_label.setObjectName("sectionHint")
        self.status_label.setWordWrap(True)
        section.body.addWidget(self.status_label)
        return section

    def _build_about_section(self) -> DrawerSection:
        info = platform_info.describe()
        section = DrawerSection("关于", f"FastGuard 移动端 · Qt6 / PySide6 {info['pyside']}")
        for text in (
            f"Qt 版本：{info['qt']}",
            f"Python：{info['python']}（{info['bits']}）",
            f"平台：{info['platform']} {info['machine']}",
        ):
            label = QtWidgets.QLabel(text)
            label.setObjectName("sectionHint")
            section.body.addWidget(label)

        self.reset_button = QtWidgets.QPushButton("恢复默认值")
        self.reset_button.setObjectName("ghostButton")
        self.reset_button.setCursor(QtCore.Qt.PointingHandCursor)
        self.reset_button.clicked.connect(self.reset_requested.emit)
        section.body.addWidget(self.reset_button)
        return section

    # ------------------------------------------------------------------ 数据同步
    def apply_settings(self, settings: MobileSettings) -> None:
        """用本地配置刷新控件（不触发指令下发）。"""
        self._settings = settings
        self._loading = True
        self.camera_control.set_value(settings.camera_index)
        self.size_control.set_value(settings.inference_size)
        self.weak_slider.setValue(int(round(settings.weak_conf * _WEAK_CONF_SCALE)))
        self.edge_slider.setValue(int(round(settings.edge_strength * _EDGE_SCALE)))
        self.bev_checkbox.setChecked(bool(settings.show_bev))
        self.host_edit.setText(settings.host)
        self.port_edit.setText(str(settings.port))
        self._refresh_threshold_labels()
        self._refresh_camera_hint()
        self._loading = False

    def apply_server_state(self, status: Dict[str, Any]) -> None:
        """用服务端返回的状态纠正界面（例如服务端由命令行启动了其它摄像头）。"""
        if not status:
            return
        self._loading = True
        if "source" in status:
            try:
                self.camera_control.set_value(int(status["source"]))
            except (TypeError, ValueError):
                pass
        if "inference_size" in status:
            try:
                self.size_control.set_value(int(status["inference_size"]))
            except (TypeError, ValueError):
                pass
        if "weak_conf" in status:
            try:
                self.weak_slider.setValue(int(round(float(status["weak_conf"]) * _WEAK_CONF_SCALE)))
            except (TypeError, ValueError):
                pass
        if "edge_strength" in status:
            try:
                self.edge_slider.setValue(int(round(float(status["edge_strength"]) * _EDGE_SCALE)))
            except (TypeError, ValueError):
                pass
        if "bev" in status:
            self.bev_checkbox.setChecked(bool(status["bev"]))
        self.set_fixed_inference_size(status.get("fixed_inference_size"))
        self._refresh_threshold_labels()
        self._refresh_camera_hint()
        self._loading = False

    def set_fixed_inference_size(self, fixed: Optional[int]) -> None:
        """固定输入模型（INT8/OpenVINO）只允许其原生尺寸。"""
        try:
            fixed_value = int(fixed) if fixed is not None else None
        except (TypeError, ValueError):
            fixed_value = None
        if fixed_value == self._fixed_inference_size:
            return
        self._fixed_inference_size = fixed_value
        self.size_control.set_enabled_values(None if fixed_value is None else [fixed_value])
        self._refresh_size_hint()

    def _refresh_size_hint(self) -> None:
        if self._fixed_inference_size is None:
            self.size_hint.setText("当前权重支持动态尺寸，可自由选择。")
        else:
            self.size_hint.setText(
                f"当前为固定输入的 INT8 模型，仅支持 {self._fixed_inference_size} px"
                "（改用 FP32 权重即可调整）。"
            )

    def set_status_text(self, text: str) -> None:
        self.status_label.setText(text)

    def set_endpoint_values(self, host: str, port: int) -> None:
        self._loading = True
        self.host_edit.setText(host)
        self.port_edit.setText(str(port))
        self._loading = False

    # ------------------------------------------------------------------ 取值
    def current_settings(self) -> MobileSettings:
        """收集界面上的当前配置。"""
        base = MobileSettings.from_dict(self._settings.to_dict())
        base.camera_index = int(self.camera_control.value())
        base.inference_size = int(self.size_control.value())
        base.weak_conf = self.weak_slider.value() / _WEAK_CONF_SCALE
        base.edge_strength = self.edge_slider.value() / _EDGE_SCALE
        base.show_bev = bool(self.bev_checkbox.isChecked())
        base.host = self.host_edit.text().strip() or base.host
        base.port = self.port_edit.text().strip() or base.port
        return base.normalize()

    def weak_conf(self) -> float:
        return self.weak_slider.value() / _WEAK_CONF_SCALE

    def edge_strength(self) -> float:
        return self.edge_slider.value() / _EDGE_SCALE

    def inference_size(self) -> int:
        return int(self.size_control.value())

    def camera_index(self) -> int:
        return int(self.camera_control.value())

    def bev_enabled(self) -> bool:
        return bool(self.bev_checkbox.isChecked())

    # ------------------------------------------------------------------ 交互
    def _refresh_threshold_labels(self) -> None:
        self.weak_value_label.setText(f"{self.weak_conf():.2f}")
        self.edge_value_label.setText(f"{self.edge_strength():.1f}")

    def _refresh_camera_hint(self) -> None:
        index = self.camera_index()
        name = "后置主摄" if index == 0 else ("前置摄像头" if index == 1 else f"摄像头 {index}")
        self.camera_hint.setText(f"当前：{name}（序号 {index}）")

    def _on_camera_changed(self, value: Any) -> None:
        self._refresh_camera_hint()
        if self._loading:
            return
        self.camera_changed.emit(int(value))

    def _on_threshold_moved(self, _value: int) -> None:
        self._refresh_threshold_labels()
        if self._loading:
            return
        self._threshold_timer.start()

    def _emit_thresholds(self) -> None:
        self.thresholds_changed.emit(self.weak_conf(), self.edge_strength())

    def _on_size_changed(self, value: Any) -> None:
        if self._loading:
            return
        self.inference_size_changed.emit(int(value))

    def _on_bev_toggled(self, checked: bool) -> None:
        if self._loading:
            return
        self.bev_toggled.emit(bool(checked))

    def _on_endpoint_submitted(self) -> None:
        host = self.host_edit.text().strip()
        try:
            port = int(self.port_edit.text().strip())
        except ValueError:
            self.set_status_text("端口必须是数字")
            return
        if not host:
            self.set_status_text("请填写主机地址")
            return
        self.endpoint_changed.emit(host, port)

    def options_summary(self) -> List[str]:
        """当前设置的可读摘要（用于状态栏/日志）。"""
        return [
            f"摄像头 {self.camera_index()}",
            f"推理尺寸 {self.inference_size()}px",
            f"阈值 {self.weak_conf():.2f}/{self.edge_strength():.1f}",
        ]
