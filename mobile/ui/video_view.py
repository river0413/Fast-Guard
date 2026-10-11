"""推理画面显示区。

移动端只显示 **AI 推理画面**（原来的"预处理画面"已按设计要求省略），
可选在地图右下角叠加一个小的 BEV 俯视窗口。
"""

from __future__ import annotations

from typing import Optional

from PySide6 import QtCore, QtGui, QtWidgets

from mobile.ui import theme


class VideoSurface(QtWidgets.QWidget):
    """等比缩放显示推理画面的黑色画布，支持可选 BEV 画中画。"""

    def __init__(self, parent: Optional[QtWidgets.QWidget] = None) -> None:
        super().__init__(parent)
        self.setObjectName("rootSurface")
        self.setMinimumSize(240, 320)
        self.setAttribute(QtCore.Qt.WA_OpaquePaintEvent, True)
        self._image: Optional[QtGui.QImage] = None
        self._bev: Optional[QtGui.QImage] = None
        self._bev_visible = False
        self._placeholder_title = "等待推理画面"
        self._placeholder_hint = "正在连接推理服务…"

    # ------------------------------------------------------------------ 接口
    def set_frame(self, image: QtGui.QImage, bev: Optional[QtGui.QImage] = None) -> None:
        self._image = image
        if bev is not None:
            self._bev = bev
        self.update()

    def set_bev_visible(self, visible: bool) -> None:
        self._bev_visible = bool(visible)
        self.update()

    def bev_visible(self) -> bool:
        return self._bev_visible

    def set_placeholder(self, title: str, hint: str = "") -> None:
        self._placeholder_title = title
        self._placeholder_hint = hint
        self._image = None
        self._bev = None
        self.update()

    def frame_size(self) -> QtCore.QSize:
        return self._image.size() if self._image is not None else QtCore.QSize()

    # ------------------------------------------------------------------ 绘制
    def paintEvent(self, event: QtGui.QPaintEvent) -> None:  # noqa: D102 - Qt 回调
        painter = QtGui.QPainter(self)
        painter.fillRect(self.rect(), QtGui.QColor("#000000"))
        painter.setRenderHint(QtGui.QPainter.SmoothPixmapTransform, True)
        painter.setRenderHint(QtGui.QPainter.Antialiasing, True)

        if self._image is None or self._image.isNull():
            self._paint_placeholder(painter)
        else:
            target = self._fitted_rect(self._image)
            painter.drawImage(target, self._image)

        if self._bev_visible and self._bev is not None and not self._bev.isNull():
            self._paint_bev(painter)
        painter.end()

    def _fitted_rect(self, image: QtGui.QImage) -> QtCore.QRect:
        available = self.rect()
        scaled = image.size().scaled(available.size(), QtCore.Qt.KeepAspectRatio)
        left = available.x() + (available.width() - scaled.width()) // 2
        top = available.y() + (available.height() - scaled.height()) // 2
        return QtCore.QRect(left, top, scaled.width(), scaled.height())

    def _paint_placeholder(self, painter: QtGui.QPainter) -> None:
        painter.setPen(QtGui.QColor(theme.TEXT_MUTED))
        font = painter.font()
        font.setPointSizeF(max(13.0, self.height() * 0.035))
        font.setBold(True)
        painter.setFont(font)
        title_rect = QtCore.QRect(20, 0, max(1, self.width() - 40), self.height() // 2)
        painter.drawText(title_rect, QtCore.Qt.AlignHCenter | QtCore.Qt.AlignBottom, self._placeholder_title)

        if self._placeholder_hint:
            hint_font = painter.font()
            hint_font.setPointSizeF(max(10.0, self.height() * 0.024))
            hint_font.setBold(False)
            painter.setFont(hint_font)
            painter.setPen(QtGui.QColor(theme.BORDER).lighter(140))
            hint_rect = QtCore.QRect(24, self.height() // 2 + 12, max(1, self.width() - 48), self.height() // 3)
            painter.drawText(
                hint_rect,
                QtCore.Qt.AlignHCenter | QtCore.Qt.AlignTop | QtCore.Qt.TextWordWrap,
                self._placeholder_hint,
            )

    def _paint_bev(self, painter: QtGui.QPainter) -> None:
        margin = max(10, self.width() // 40)
        target_height = int(self.height() * 0.30)
        aspect = self._bev.width() / max(1, self._bev.height())
        target_width = int(target_height * aspect)
        rect = QtCore.QRect(
            self.width() - target_width - margin,
            self.height() - target_height - margin,
            target_width,
            target_height,
        )
        painter.setBrush(QtGui.QColor(0, 0, 0, 170))
        painter.setPen(QtGui.QPen(QtGui.QColor(theme.SAFE), 2))
        painter.drawRoundedRect(rect.adjusted(-2, -2, 2, 2), 10, 10)
        painter.drawImage(rect, self._bev)
