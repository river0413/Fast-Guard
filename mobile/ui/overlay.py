"""推理画面上方的悬浮控件：左上角汉堡设置按钮 + 右上角"卸载推理"状态徽标。"""

from __future__ import annotations

from typing import Optional

from PySide6 import QtCore, QtGui, QtWidgets

from mobile.client.transport import describe_link_state
from mobile.ui import theme

#: 悬浮层高度（移动端拇指可达区域）。
TOP_BAR_HEIGHT = 64


class HamburgerButton(QtWidgets.QAbstractButton):
    """左上角汉堡按钮（三条横线，自绘以保证各平台渲染一致）。"""

    def __init__(self, parent: Optional[QtWidgets.QWidget] = None, size: int = theme.TOUCH_TARGET) -> None:
        super().__init__(parent)
        self.setFixedSize(size, size)
        self.setCursor(QtCore.Qt.PointingHandCursor)
        self.setToolTip("设置：摄像头 / 阈值 / 推理图片大小")
        self.setAccessibleName("打开设置")

    def paintEvent(self, event: QtGui.QPaintEvent) -> None:  # noqa: D102 - Qt 回调
        painter = QtGui.QPainter(self)
        painter.setRenderHint(QtGui.QPainter.Antialiasing, True)
        rect = self.rect().adjusted(1, 1, -1, -1)
        painter.setBrush(QtGui.QColor(9, 9, 11, 180))
        painter.setPen(QtGui.QPen(QtGui.QColor(255, 255, 255, 40), 1))
        painter.drawEllipse(rect)

        pen = QtGui.QPen(QtGui.QColor(theme.TEXT), 2.2)
        pen.setCapStyle(QtCore.Qt.RoundCap)
        painter.setPen(pen)
        width = self.width() * 0.42
        center_x = self.width() / 2.0
        for ratio in (0.36, 0.5, 0.64):
            y = self.height() * ratio
            painter.drawLine(
                QtCore.QPointF(center_x - width / 2.0, y),
                QtCore.QPointF(center_x + width / 2.0, y),
            )
        painter.end()


class OffloadBadge(QtWidgets.QFrame):
    """右上角徽标：显示"卸载推理"及其运行状态。

    该徽标取代了原先的"帧率 / 稳定性"等指标，只反映推理是否已卸载到服务端运行。
    """

    def __init__(self, parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("offloadBadge")
        self.setStyleSheet(
            """
            QFrame#offloadBadge {
                background-color: rgba(9, 9, 11, 190);
                border: 1px solid rgba(255, 255, 255, 38);
                border-radius: 18px;
            }
            QLabel { background: transparent; border: none; }
            """
        )
        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(14, 8, 16, 8)
        layout.setSpacing(8)

        self._dot = QtWidgets.QLabel()
        self._dot.setFixedSize(10, 10)
        self._title = QtWidgets.QLabel("卸载推理")
        self._title.setStyleSheet(theme.font_style(14, 700, theme.TEXT))
        self._state = QtWidgets.QLabel("连接中")
        self._state.setStyleSheet(theme.font_style(13, 500, theme.TEXT_MUTED))

        layout.addWidget(self._dot)
        layout.addWidget(self._title)
        layout.addWidget(self._state)
        self._state_code = "connecting"
        self.set_state("connecting", "正在连接推理服务")

    def set_state(self, state: str, detail: str = "") -> None:
        text, color = describe_link_state(state)
        self._state_code = state
        self._dot.setStyleSheet(f"background-color: {color}; border-radius: 5px;")
        self._state.setText(text)
        self._state.setStyleSheet(theme.font_style(13, 600, color))
        self.setToolTip(detail or f"卸载推理：{text}")

    def state(self) -> str:
        """当前连接状态码（connecting / online / stalled / offline）。"""
        return self._state_code

    def state_text(self) -> str:
        return self._state.text()

    def title_text(self) -> str:
        return self._title.text()


class TopBar(QtWidgets.QWidget):
    """悬浮在画面上方的顶栏：左汉堡、右徽标，底部带渐变遮罩保证可读性。"""

    settings_clicked = QtCore.Signal()

    def __init__(self, parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)
        self.setFixedHeight(TOP_BAR_HEIGHT)
        self.setAttribute(QtCore.Qt.WA_TranslucentBackground, True)

        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(10, 8, 12, 8)
        layout.setSpacing(10)

        self.hamburger = HamburgerButton(self)
        self.badge = OffloadBadge(self)
        layout.addWidget(self.hamburger, 0, QtCore.Qt.AlignVCenter)
        layout.addStretch(1)
        layout.addWidget(self.badge, 0, QtCore.Qt.AlignVCenter)

        self.hamburger.clicked.connect(self.settings_clicked.emit)

    def set_link_state(self, state: str, detail: str = "") -> None:
        self.badge.set_state(state, detail)

    def paintEvent(self, event: QtGui.QPaintEvent) -> None:  # noqa: D102 - Qt 回调
        painter = QtGui.QPainter(self)
        gradient = QtGui.QLinearGradient(0, 0, 0, self.height())
        gradient.setColorAt(0.0, QtGui.QColor(0, 0, 0, 190))
        gradient.setColorAt(1.0, QtGui.QColor(0, 0, 0, 0))
        painter.fillRect(self.rect(), gradient)
        painter.end()
