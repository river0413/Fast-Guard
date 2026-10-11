"""运行平台信息：Python / Qt 版本与位数（用于校验 64 位支持）。"""

from __future__ import annotations

import platform
import struct
import sys
from typing import Dict


def pointer_bits() -> int:
    """当前解释器的位数（64 / 32）。"""
    return struct.calcsize("P") * 8


def is_64bit() -> bool:
    return pointer_bits() >= 64


def qt_version() -> str:
    """返回 Qt 运行时版本；未安装 Qt 绑定时返回空串。"""
    try:
        from PySide6 import QtCore  # type: ignore import-not-found
    except Exception:  # pragma: no cover - 未安装 PySide6 时
        try:
            from PyQt5 import QtCore  # type: ignore import-not-found
        except Exception:
            return ""
    try:
        return str(QtCore.qVersion())
    except Exception:  # pragma: no cover - 防御性
        return ""


def pyside_version() -> str:
    try:
        from PySide6 import QtCore  # type: ignore import-not-found
    except Exception:
        return ""
    return str(getattr(QtCore, "__version__", ""))


def describe() -> Dict[str, str]:
    return {
        "python": sys.version.split()[0],
        "bits": f"{pointer_bits()} 位",
        "platform": platform.system(),
        "machine": platform.machine(),
        "qt": qt_version(),
        "pyside": pyside_version(),
    }


def banner() -> str:
    info = describe()
    return (
        f"FastGuard 移动端界面（Qt6 / PySide6 {info['pyside']}，Qt {info['qt']}）"
        f" · Python {info['python']} {info['bits']} · {info['platform']}"
    )
