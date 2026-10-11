"""为 Android 打包准备一个**精简的**工程目录。

``pyside6-android-deploy`` 会把 ``project_dir`` 整个打进 APK，而仓库根目录包含
``venv/``、``dist/``、演示文稿等大量无关内容（数百 MB～数 GB）。因此这里生成一个
只含运行时必需文件的 staging 目录::

    build/android/project/
    ├── main.py            # 入口（工具要求入口文件必须叫 main.py）
    └── mobile/            # 仅 __init__/app/protocol/platform_info + client/ + ui/
                           # 不含 backend/（PyQt5 推理服务端）与 packaging/

这样既保持 ``mobile.*`` 的导入路径不变（无需改任何业务代码），又让 APK 尽量小。
"""

from __future__ import annotations

import shutil
from pathlib import Path
from typing import List, Optional

from mobile.packaging.android_kit.common import (
    RUNTIME_PACKAGE_DIRS,
    RUNTIME_PACKAGE_FILES,
    STAGING_DIRNAME,
)

#: 仓库根目录（mobile/packaging/android_kit/ → 上溯四级）。
REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent

#: 入口文件模板内容（会写到 staging/main.py）。
ENTRY_TEMPLATE = '''"""FastGuard 移动端 APK 入口。

``pyside6-android-deploy`` 要求工程入口文件名为 ``main.py``；这里只做
``sys.path`` 准备并转交给 :func:`mobile.app.main`，不包含任何业务逻辑。
"""

import os
import sys

APP_DIR = os.path.dirname(os.path.abspath(__file__))
if APP_DIR not in sys.path:
    sys.path.insert(0, APP_DIR)

from mobile.app import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main(["--fullscreen"]))
'''


def staging_dir(build_root: Path) -> Path:
    return Path(build_root) / STAGING_DIRNAME


def stage_project(build_root: Path, repo_root: Optional[Path] = None) -> Path:
    """生成（或刷新）staging 目录，返回其路径。"""
    repo = Path(repo_root) if repo_root else REPO_ROOT
    target = staging_dir(build_root)
    package_dir = target / "mobile"

    if target.exists():
        shutil.rmtree(target)
    package_dir.mkdir(parents=True)

    source_package = repo / "mobile"
    if not source_package.is_dir():
        raise FileNotFoundError(f"找不到移动端源码目录：{source_package}")

    for name in RUNTIME_PACKAGE_FILES:
        source = source_package / name
        if source.is_file():
            shutil.copy2(source, package_dir / name)
    for name in RUNTIME_PACKAGE_DIRS:
        source = source_package / name
        if source.is_dir():
            shutil.copytree(
                source,
                package_dir / name,
                ignore=shutil.ignore_patterns("__pycache__", "*.pyc"),
            )

    (target / "main.py").write_text(ENTRY_TEMPLATE, encoding="utf-8")
    return target


def staged_files(build_root: Path) -> List[str]:
    """列出 staging 目录内的相对路径（用于日志/断言）。"""
    target = staging_dir(build_root)
    if not target.is_dir():
        return []
    return sorted(str(path.relative_to(target)).replace("\\", "/") for path in target.rglob("*") if path.is_file())
