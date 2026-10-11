"""FastGuard 移动端（Qt6 / PySide6）启动入口。

用法::

    python -m mobile.app                                  # 桌面预览：自动拉起本地推理服务
    python -m mobile.app --no-backend                     # 只启动界面（推理服务已在运行）
    python -m mobile.app --host 192.168.1.20 --port 8765   # 连接车机 / PC 上的推理服务

移动端只负责"显示推理画面 + 下发参数"，推理本身由
``mobile.backend.frame_server`` 包装的既有 ``VideoThread`` 完成（架构不变）。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import List, Optional

from PySide6 import QtCore, QtWidgets

from mobile import platform_info, protocol
from mobile.client.backend_launcher import ensure_backend, is_android, stop_backend
from mobile.client.settings import MobileSettings
from mobile.ui import theme
from mobile.ui.main_window import MobileWindow


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="FastGuard 移动端界面（Qt6）")
    parser.add_argument("--host", default=None, help="推理服务地址（默认读取本地配置）")
    parser.add_argument("--port", type=int, default=None, help="推理服务端口（默认读取本地配置）")
    parser.add_argument("--settings", default=None, help="配置文件路径")
    parser.add_argument("--no-backend", action="store_true", help="不自动拉起本地推理服务")
    parser.add_argument(
        "--fullscreen",
        action="store_true",
        help="全屏显示（Android 上默认启用）",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)
    settings_path = Path(args.settings) if args.settings else MobileSettings.default_path()
    settings = MobileSettings.load(settings_path)
    if args.host:
        settings.host = args.host
    if args.port:
        settings.port = int(args.port)
    if args.no_backend:
        settings.autostart_backend = False
    settings.normalize()

    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(sys.argv[:1])
    app.setApplicationName("FastGuard Mobile")
    app.setOrganizationName("FastGuard")
    theme.apply_theme(app)

    print(platform_info.banner(), flush=True)
    if not platform_info.is_64bit():
        print("警告：当前 Python 为 32 位，Qt6 需要 64 位运行环境。", flush=True)

    backend_process = None
    if settings.autostart_backend:
        backend_process = ensure_backend(settings)

    window = MobileWindow(settings, settings_path=settings_path)
    window.start()
    fullscreen = args.fullscreen or is_android()
    if fullscreen:
        window.showFullScreen()
    else:
        window.show()

    try:
        return app.exec()
    finally:
        window.client.stop()
        stop_backend(backend_process)


if __name__ == "__main__":
    raise SystemExit(main())
