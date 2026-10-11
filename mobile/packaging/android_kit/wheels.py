"""解析并下载 64 位 Android wheel。

Android 版本 **不发布在 PyPI 上**，只在 Qt 官方下载站
（``download.qt.io/official_releases/QtForPython``）提供。本模块负责：

1. 读取站点目录列表，找出与宿主 PySide6 **版本一致**的 64 位 wheel；
2. 下载到本地缓存目录（``build/android/wheels``），供 ``pysidedeploy.spec`` 引用；
3. 拒绝任何 32 位（armeabi-v7a / x86）wheel。
"""

from __future__ import annotations

from pathlib import Path
from typing import Dict, List, Optional, Tuple

from mobile.packaging.android_kit.common import (
    ARCHITECTURES,
    download_file,
    extract_wheel_names,
    fetch_directory_index,
    filter_arch_wheels,
    is_64bit_wheel_name,
    wheel_url,
    wheel_version,
)


def host_pyside_version() -> Optional[str]:
    """宿主已安装的 PySide6 版本（未安装时返回 ``None``）。"""
    try:
        from PySide6 import QtCore

        return str(getattr(QtCore, "__version__", "")) or None
    except Exception:
        return None


def list_remote_wheels(package: str, archive_html: Optional[str] = None) -> List[str]:
    """列出 Qt 官方站点上某个包的全部 wheel 文件名。"""
    html = archive_html if archive_html is not None else fetch_directory_index(package)
    return extract_wheel_names(html)


def available_64bit_wheels(arch: str, per_package_html: Optional[Dict[str, str]] = None) -> Dict[str, List[str]]:
    """列出指定 64 位 ABI 可用的 PySide6 / shiboken6 wheel。"""
    result: Dict[str, List[str]] = {}
    for package in ("pyside6", "shiboken6"):
        html = (per_package_html or {}).get(package)
        names = list_remote_wheels(package, html)
        result[package] = filter_arch_wheels(names, arch, package)
    return result


def pick_wheel(filenames: List[str], version: Optional[str]) -> Optional[str]:
    """优先选择版本与宿主一致的 wheel；否则退回版本号最大的一个。"""
    if not filenames:
        return None
    if version:
        exact = [name for name in filenames if wheel_version(name) == version]
        if exact:
            return sorted(exact)[-1]

    def sort_key(name: str):
        raw = wheel_version(name) or "0"
        parts = []
        for chunk in raw.split("."):
            parts.append(int(chunk) if chunk.isdigit() else 0)
        while len(parts) < 4:
            parts.append(0)
        return tuple(parts)

    return sorted(filenames, key=sort_key)[-1]


def resolve_wheels(
    cache_dir: Path,
    arch: str = "aarch64",
    version: Optional[str] = None,
    per_package_html: Optional[Dict[str, str]] = None,
    download: bool = True,
) -> Tuple[Optional[Path], Optional[Path], List[str]]:
    """准备指定 ABI 的 PySide6 / shiboken6 watch。

    返回 ``(pyside_wheel, shiboken_wheel, notes)``；缺少任一 wheel 时对应项为 ``None``，
    ``notes`` 中给出原因。
    """
    notes: List[str] = []
    if arch not in ARCHITECTURES:
        raise ValueError(f"只支持 64 位 ABI：{sorted(ARCHITECTURES)}，收到 {arch!r}")

    cache = Path(cache_dir)
    target_version = version or host_pyside_version()
    available = available_64bit_wheels(arch, per_package_html)

    resolved: Dict[str, Optional[Path]] = {}
    for package in ("pyside6", "shiboken6"):
        candidates = available.get(package, [])
        if not candidates:
            notes.append(f"Qt 官方下载站上未找到 {package} 的 64 位 Android wheel（abi={arch}）")
            resolved[package] = None
            continue

        chosen = pick_wheel(candidates, target_version)
        if chosen is None:  # pragma: no cover - 逻辑上不会发生
            resolved[package] = None
            continue
        if target_version and wheel_version(chosen) != target_version:
            notes.append(
                f"{package} 没有与宿主 PySide6 {target_version} 匹配的 64 位 wheel，"
                f"改用 {wheel_version(chosen)}（如需完全一致，请把宿主 PySide6 也装成该版本）"
            )
        if not is_64bit_wheel_name(chosen):
            notes.append(f"拒绝 32 位 wheel：{chosen}")
            resolved[package] = None
            continue

        path = cache / chosen
        if not path.exists() and download:
            try:
                download_file(wheel_url(package, chosen), path)
            except Exception as exc:  # pragma: no cover - 网络异常
                notes.append(f"下载 {chosen} 失败：{exc}")
                resolved[package] = None
                continue
        if not path.exists():
            notes.append(f"{chosen} 尚未下载（跳过下载时请自行放入 {cache}）")
            resolved[package] = None
            continue
        resolved[package] = path

    return resolved.get("pyside6"), resolved.get("shiboken6"), notes
