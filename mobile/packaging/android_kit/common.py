"""Android 打包的常量与基础工具（只用标准库，便于单独测试）。"""

from __future__ import annotations

import re
import struct
import sys
import time
import urllib.request
from pathlib import Path
from typing import Iterable, List, Optional

#: Qt 官方 wheel 下载目录（Android wheel 只在此发布，PyPI 上没有）。
QT_DOWNLOAD_BASE = "https://download.qt.io/official_releases/QtForPython"

#: 目标 ABI → 说明。只保留 64 位；32 位（armeabi-v7a / x86）不受支持。
ARCHITECTURES = {
    "aarch64": {"android_abi": "arm64-v8a", "label": "arm64-v8a（真机）"},
    "x86_64": {"android_abi": "x86_64", "label": "x86_64（64 位模拟器）"},
}

#: 会被明确拒绝的 32 位 ABI 片段。
REJECTED_32BIT_MARKERS = ("armeabi_v7a", "armeabi-v7a", "armeabi", "android_x86.", "i686", "win32", "x86-32")

#: 认可的 64 位 ABI 片段（Qt 的 Android wheel 使用 ``android_aarch64`` / ``android_x86_64``）。
SUPPORTED_64BIT_MARKERS = ("android_aarch64", "android_x86_64", "arm64_v8a", "arm64-v8a", "amd64")

#: Android wheel 的文件名模式（官方命名里 Qt 版本号出现两次）。
#: 例如 ``pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl``。
WHEEL_NAME_RE = re.compile(
    r"^(?P<pkg>pyside6|shiboken6)-(?P<ver>[\d.]+)(?:-(?P<qtver>[\d.]+))?"
    r"-(?P<pytag>cp\d+|py3)(?:-(?P<abitag>[a-z0-9_]+))?"
    r"-android_(?P<arch>aarch64|x86_64)\.whl$",
    re.IGNORECASE,
)

#: 打包用到的包 → Qt 下载目录名。
PACKAGE_DIRS = {"pyside6": "pyside6", "shiboken6": "shiboken6"}

#: 构建产物根目录（已在 .gitignore 中忽略 build/）。
BUILD_ROOT = Path(__file__).resolve().parent.parent.parent.parent / "build" / "android"
STAGING_DIRNAME = "project"
WHEEL_CACHE_DIRNAME = "wheels"
OUTPUT_DIRNAME = "dist"

#: 进入 Android APK 的包内容（推理服务端 mobile/backend 与打包脚本不需要）。
RUNTIME_PACKAGE_DIRS = ("client", "ui")
RUNTIME_PACKAGE_FILES = ("__init__.py", "app.py", "protocol.py", "platform_info.py")


def pointer_bits() -> int:
    return struct.calcsize("P") * 8


def is_64bit_host() -> bool:
    return pointer_bits() >= 64


def is_unix_host() -> bool:
    """``pyside6-android-deploy`` 只在 Unix（Linux / macOS）主机上可用。"""
    return not sys.platform.startswith("win")


def is_64bit_wheel_name(filename: str) -> bool:
    """仅 64 位 Android wheel 可用（arm64-v8a / x86_64）。"""
    name = str(filename).lower()
    if not name.endswith(".whl"):
        return False
    if any(marker in name for marker in REJECTED_32BIT_MARKERS):
        return False
    return any(marker in name for marker in SUPPORTED_64BIT_MARKERS)


def wheel_arch(filename: str) -> Optional[str]:
    """从 wheel 文件名解析 ABI 名（``aarch64`` / ``x86_64``）。"""
    match = WHEEL_NAME_RE.match(Path(str(filename)).name)
    return match.group("arch").lower() if match else None


def wheel_package(filename: str) -> Optional[str]:
    match = WHEEL_NAME_RE.match(Path(str(filename)).name)
    return match.group("pkg").lower() if match else None


def wheel_version(filename: str) -> Optional[str]:
    match = WHEEL_NAME_RE.match(Path(str(filename)).name)
    return match.group("ver") if match else None


def is_android_wheel(filename: str) -> bool:
    return bool(WHEEL_NAME_RE.match(Path(str(filename)).name))


def filter_arch_wheels(filenames: Iterable[str], arch: str, package: str) -> List[str]:
    """从目录列表里挑出指定包、指定 ABI 的 64 位 Android wheel（按文件名排序）。"""
    picked = [
        name
        for name in filenames
        if is_android_wheel(name)
        and wheel_package(name) == str(package).lower()
        and wheel_arch(name) == str(arch).lower()
        and is_64bit_wheel_name(name)
    ]
    return sorted(picked)


def fetch_directory_index(package: str, timeout: float = 60.0, attempts: int = 3) -> str:
    """读取 Qt 下载站点上某个包的目录列表（Apache autoindex 的 HTML）。

    Qt 下载站偶发 TLS 中断，因此带指数退避重试。
    """
    directory = PACKAGE_DIRS.get(str(package).lower(), str(package).lower())
    url = f"{QT_DOWNLOAD_BASE}/{directory}/"
    last_error: Optional[Exception] = None
    for attempt in range(1, max(1, attempts) + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "fastguard-android-packager/1.0"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read().decode("utf-8", errors="ignore")
        except Exception as exc:  # noqa: BLE001 - 网络层异常种类多，统一重试
            last_error = exc
            if attempt < attempts:
                time.sleep(1.5 * attempt)
    raise RuntimeError(f"读取 {url} 失败（已重试 {attempts} 次）：{last_error}") from last_error


def extract_wheel_names(html: str) -> List[str]:
    """从目录 HTML 中提取 ``*.whl`` 文件名（忽略 ``.mirrorlist`` 等附属链接）。"""
    names = re.findall(r'href="([^"]+\.whl)"', html or "")
    return sorted({name.split("/")[-1] for name in names})


def wheel_url(package: str, filename: str) -> str:
    directory = PACKAGE_DIRS.get(str(package).lower(), str(package).lower())
    return f"{QT_DOWNLOAD_BASE}/{directory}/{filename}"


def download_file(url: str, target: Path, timeout: float = 600.0, attempts: int = 3) -> Path:
    """下载单个文件到 ``target``（已存在且非空时跳过；失败时重试）。"""
    target = Path(target)
    if target.exists() and target.stat().st_size > 0:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name(target.name + ".part")
    last_error: Optional[Exception] = None
    for attempt in range(1, max(1, attempts) + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "fastguard-android-packager/1.0"})
            with urllib.request.urlopen(request, timeout=timeout) as response, open(temp, "wb") as handle:
                while True:
                    chunk = response.read(1024 * 256)
                    if not chunk:
                        break
                    handle.write(chunk)
            temp.replace(target)
            return target
        except Exception as exc:  # noqa: BLE001 - 网络层异常种类多，统一重试
            last_error = exc
            temp.unlink(missing_ok=True)
            if attempt < attempts:
                time.sleep(2.0 * attempt)
    raise RuntimeError(f"下载 {url} 失败（已重试 {attempts} 次）：{last_error}") from last_error
