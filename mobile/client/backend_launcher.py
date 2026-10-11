"""桌面端一键体验：若推理服务未启动，则由客户端自动拉起一个本地推理服务进程。

手机（Android）上无法派生 Python 子进程，因此该能力只在桌面平台生效；
移动端连接的是车机 / PC 上的推理服务（见 ``mobile/README.md``）。
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

from mobile.client.settings import MobileSettings

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent

#: 只有指向本机的地址才需要自动拉起本地服务。
LOCAL_HOSTS = {"127.0.0.1", "localhost", "0.0.0.0", "::1"}

DEFAULT_LOG_FILE = PROJECT_ROOT / "logs" / "mobile_backend.log"


def is_android() -> bool:
    """判断当前是否运行在 Android（PySide6 打包环境）上。"""
    return sys.platform.startswith("android") or "ANDROID_ARGUMENT" in os.environ


def port_is_open(host: str, port: int, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def build_backend_command(settings: MobileSettings, host: str = "0.0.0.0") -> List[str]:
    return [
        sys.executable,
        "-m",
        "mobile.backend.frame_server",
        "--host",
        host,
        "--port",
        str(settings.port),
        "--source",
        str(settings.camera_index),
        "--inference-size",
        str(settings.inference_size),
        "--weak-conf",
        str(settings.weak_conf),
        "--edge-strength",
        str(settings.edge_strength),
    ]


def ensure_backend(
    settings: MobileSettings,
    wait_seconds: float = 15.0,
    log_file: Optional[Path] = None,
) -> Optional[subprocess.Popen]:
    """确保本地推理服务可用。

    返回本次启动的子进程（若服务本就在运行，或当前平台不支持派生进程，则返回 ``None``）。
    """
    if not settings.autostart_backend or settings.host not in LOCAL_HOSTS or is_android():
        return None
    if port_is_open(settings.host, settings.port):
        return None

    target = Path(log_file) if log_file else DEFAULT_LOG_FILE
    target.parent.mkdir(parents=True, exist_ok=True)
    log_handle = open(target, "a", encoding="utf-8")
    log_handle.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} 启动本地推理服务 ===\n")
    log_handle.flush()

    creationflags = 0
    if os.name == "nt":  # 避免弹出控制台窗口
        creationflags = getattr(subprocess, "CREATE_NO_WINDOW", 0)

    process = subprocess.Popen(
        build_backend_command(settings),
        cwd=str(PROJECT_ROOT),
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        creationflags=creationflags,
    )

    deadline = time.time() + wait_seconds
    while time.time() < deadline:
        if process.poll() is not None:
            return process  # 进程已退出（例如端口被占用），交由界面显示错误
        if port_is_open(settings.host, settings.port, timeout=0.3):
            return process
        time.sleep(0.4)
    return process


def stop_backend(process: Optional[subprocess.Popen]) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:  # pragma: no cover - 强制结束
        process.kill()
