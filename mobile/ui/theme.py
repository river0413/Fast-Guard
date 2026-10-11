"""移动端配色与全局样式（深色，与桌面端 FastGuard 视觉保持一致）。"""

from __future__ import annotations

from typing import Optional

BACKGROUND = "#09090b"
SURFACE = "#18181b"
SURFACE_ALT = "#27272a"
BORDER = "#3f3f46"
TEXT = "#f4f4f5"
TEXT_MUTED = "#a1a1aa"
ACCENT = "#6366f1"
ACCENT_ALT = "#818cf8"
SAFE = "#10b981"
WARNING = "#f59e0b"
DANGER = "#ef4444"

FONT_FAMILY = "'Microsoft YaHei', 'Noto Sans CJK SC', 'Segoe UI', sans-serif"

#: 移动端最小可点区域（触控友好）。
TOUCH_TARGET = 48


def font_style(size: int, weight: int = 500, color: str = TEXT) -> str:
    return f"font-family: {FONT_FAMILY}; font-size: {size}px; font-weight: {weight}; color: {color};"


def global_qss() -> str:
    return f"""
    QWidget {{
        font-family: {FONT_FAMILY};
        color: {TEXT};
    }}
    QWidget#rootSurface {{
        background-color: #000000;
    }}
    QFrame#settingsDrawer {{
        background-color: {SURFACE};
        border-right: 1px solid {BORDER};
    }}
    QFrame#drawerSection {{
        background-color: {BACKGROUND};
        border: 1px solid {SURFACE_ALT};
        border-radius: 14px;
    }}
    QLabel#sectionTitle {{
        {font_style(15, 700, TEXT)}
    }}
    QLabel#sectionHint {{
        {font_style(12, 400, TEXT_MUTED)}
    }}
    QLabel#valueLabel {{
        {font_style(15, 700, ACCENT_ALT)}
    }}
    QPushButton#segmentButton {{
        background-color: {SURFACE_ALT};
        border: 1px solid {BORDER};
        border-radius: 10px;
        padding: 10px 12px;
        {font_style(14, 600, TEXT_MUTED)}
    }}
    QPushButton#segmentButton:checked {{
        background-color: {ACCENT};
        border: 1px solid {ACCENT_ALT};
        color: #ffffff;
    }}
    QPushButton#primaryButton {{
        background-color: {ACCENT};
        border: none;
        border-radius: 12px;
        padding: 14px;
        {font_style(15, 700, '#ffffff')}
    }}
    QPushButton#ghostButton {{
        background-color: transparent;
        border: 1px solid {BORDER};
        border-radius: 12px;
        padding: 14px;
        {font_style(15, 600, TEXT_MUTED)}
    }}
    QLineEdit {{
        background-color: {BACKGROUND};
        border: 1px solid {BORDER};
        border-radius: 10px;
        padding: 10px 12px;
        {font_style(15, 500, TEXT)}
    }}
    QSlider::groove:horizontal {{
        height: 6px;
        background: {SURFACE_ALT};
        border-radius: 3px;
    }}
    QSlider::sub-page:horizontal {{
        background: {ACCENT};
        border-radius: 3px;
    }}
    QSlider::handle:horizontal {{
        width: 26px;
        height: 26px;
        margin: -10px 0;
        border-radius: 13px;
        background: #ffffff;
    }}
    QCheckBox {{
        {font_style(15, 500, TEXT)}
        spacing: 12px;
    }}
    QCheckBox::indicator {{
        width: 30px;
        height: 30px;
        border-radius: 8px;
        border: 1px solid {BORDER};
        background: {BACKGROUND};
    }}
    QCheckBox::indicator:checked {{
        background: {ACCENT};
        border: 1px solid {ACCENT_ALT};
    }}
    QScrollArea {{
        background: transparent;
        border: none;
    }}
    QScrollBar:vertical {{
        background: transparent;
        width: 6px;
        margin: 0;
    }}
    QScrollBar::handle:vertical {{
        background: {BORDER};
        border-radius: 3px;
        min-height: 40px;
    }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{
        height: 0;
    }}
    """


def apply_theme(app: Optional[object]) -> None:
    """把全局样式应用到 QApplication。"""
    if app is not None:
        app.setStyleSheet(global_qss())
