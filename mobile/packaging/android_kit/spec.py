"""生成/校验 ``pysidedeploy.spec``。

``pyside6-android-deploy`` 与 ``pyside6-deploy`` 共用同一个 INI 配置文件。
本模块基于 PySide6 自带 ``deploy_lib/default.spec`` 的键集合生成配置，保证与
官方工具期望的字段一致；生成的 spec 会写进 staging 目录，避免污染仓库根目录。
"""

from __future__ import annotations

import configparser
import io
from pathlib import Path
from typing import Dict, List, Optional

#: 生成 spec 时的默认值（键名与官方 default.spec 保持一致）。
DEFAULT_SPEC_VALUES: Dict[str, Dict[str, str]] = {
    "app": {
        "title": "FastGuard",
        "project_dir": "",
        "input_file": "main.py",
        "exec_directory": "",
        "project_file": "",
        "icon": "",
    },
    "python": {
        "packages": "",
        # buildozer 由 pyside6-android-deploy 用来打包 Android 应用
        "android_packages": "buildozer==1.6.0,cython==0.29.33",
    },
    "qt": {
        "qml_files": "",
        "excluded_qml_plugins": "",
        "modules": "",
        "plugins": "",
    },
    "android": {
        "wheel_pyside": "",
        "wheel_shiboken": "",
        "plugins": "",
    },
    "buildozer": {
        # debug → .apk（可直接安装）；release → .aab（用于上架）
        "mode": "debug",
        "recipe_dir": "",
        "jars_dir": "",
        "ndk_path": "",
        "sdk_path": "",
        "local_libs": "",
        # 只支持 64 位 ABI
        "arch": "aarch64",
    },
}

#: 允许通过命令行覆盖的键。
_OVERRIDABLE = {
    "app.title",
    "app.exec_directory",
    "android.wheel_pyside",
    "android.wheel_shiboken",
    "buildozer.mode",
    "buildozer.arch",
    "buildozer.ndk_path",
    "buildozer.sdk_path",
    "buildozer.recipe_dir",
    "buildozer.jars_dir",
}

SPEC_FILENAME = "pysidedeploy.spec"


def installed_default_spec() -> Optional[Path]:
    """PySide6 自带的 ``default.spec``（用于交叉校验键集合）。

    直接按文件路径查找，**不导入** ``PySide6.scripts.deploy_lib``：该包的
    ``nuitka_helper`` 使用扁平导入（``from project_lib import ...``），只有在官方
    工具把 ``scripts`` 目录加进 ``sys.path`` 后才能导入成功。
    """
    try:
        import importlib.util

        module_spec = importlib.util.find_spec("PySide6")
    except Exception:  # pragma: no cover - 未安装 PySide6
        return None
    origin = getattr(module_spec, "origin", None)
    if not origin:
        return None

    root = Path(origin).resolve().parent
    for candidate in (
        root / "scripts" / "deploy_lib" / "default.spec",
        root / "scripts" / "default.spec",
    ):
        if candidate.is_file():
            return candidate
    return None


def default_spec_keys() -> Dict[str, List[str]]:
    """读取官方 ``default.spec`` 的节/键（无法读取时返回空字典）。"""
    path = installed_default_spec()
    if path is None:
        return {}
    parser = configparser.ConfigParser()
    # 官方 spec 含中文/无值键，保留大小写并允许无值
    parser.optionxform = str
    parser.read_string(path.read_text(encoding="utf-8"))
    return {section: list(parser[section].keys()) for section in parser.sections()}


def build_spec_text(
    project_dir: Path,
    exec_directory: Path,
    wheel_pyside: Path,
    wheel_shiboken: Path,
    title: str = "FastGuard",
    mode: str = "debug",
    arch: str = "aarch64",
    ndk_path: str = "",
    sdk_path: str = "",
    recipe_dir: str = "",
    jars_dir: str = "",
) -> str:
    """生成 spec 文本。"""
    if mode not in ("debug", "release"):
        raise ValueError(f"buildozer.mode 只能是 debug（.apk）或 release（.aab），收到 {mode!r}")
    if arch not in ("aarch64", "x86_64"):
        raise ValueError(f"只支持 64 位 ABI（aarch64 / x86_64），收到 {arch!r}")

    values = {section: dict(items) for section, items in DEFAULT_SPEC_VALUES.items()}
    values["app"]["title"] = title
    values["app"]["project_dir"] = str(project_dir)
    values["app"]["exec_directory"] = str(exec_directory)
    values["android"]["wheel_pyside"] = str(wheel_pyside)
    values["android"]["wheel_shiboken"] = str(wheel_shiboken)
    values["buildozer"]["mode"] = mode
    values["buildozer"]["arch"] = arch
    values["buildozer"]["ndk_path"] = ndk_path
    values["buildozer"]["sdk_path"] = sdk_path
    values["buildozer"]["recipe_dir"] = recipe_dir
    values["buildozer"]["jars_dir"] = jars_dir

    buffer = io.StringIO()
    buffer.write("# 由 mobile/packaging/android_deploy.py 生成，请勿手工修改。\n")
    buffer.write("# 对应 pyside6-android-deploy 使用的 pysidedeploy.spec。\n")
    for section, items in values.items():
        buffer.write(f"\n[{section}]\n")
        for key, value in items.items():
            buffer.write(f"{key} = {value}\n")
    return buffer.getvalue()


def write_spec(spec_path: Path, text: str) -> Path:
    spec_path = Path(spec_path)
    spec_path.parent.mkdir(parents=True, exist_ok=True)
    spec_path.write_text(text, encoding="utf-8")
    return spec_path


def read_spec(spec_path: Path) -> Dict[str, Dict[str, str]]:
    parser = configparser.ConfigParser()
    parser.optionxform = str
    parser.read_string(Path(spec_path).read_text(encoding="utf-8"))
    return {section: dict(parser[section]) for section in parser.sections()}


def validate_spec(spec_path: Path) -> List[str]:
    """校验 spec 的必要键与 64 位约束，返回问题列表（空列表表示通过）。"""
    problems: List[str] = []
    path = Path(spec_path)
    if not path.is_file():
        return [f"spec 文件不存在：{path}"]

    values = read_spec(path)
    if not values:
        return [f"spec 文件解析失败：{path}"]

    for section, keys in (("app", ("title", "input_file")), ("buildozer", ("mode", "arch"))):
        if section not in values:
            problems.append(f"缺少 [{section}] 节")
            continue
        for key in keys:
            if not str(values[section].get(key, "")).strip():
                problems.append(f"[{section}] 缺少 {key}")

    arch = str(values.get("buildozer", {}).get("arch", "")).strip()
    if arch and arch not in ("aarch64", "x86_64"):
        problems.append(f"[buildozer] arch 必须是 64 位（aarch64 / x86_64），当前为 {arch}")

    mode = str(values.get("buildozer", {}).get("mode", "")).strip()
    if mode and mode not in ("debug", "release"):
        problems.append(f"[buildozer] mode 只能是 debug / release，当前为 {mode}")

    for key in ("wheel_pyside", "wheel_shiboken"):
        value = str(values.get("android", {}).get(key, "")).strip()
        if not value:
            problems.append(f"[android] 缺少 {key}（需指向已下载的 64 位 Android wheel）")
        elif not Path(value).is_file():
            problems.append(f"[android] {key} 指向的文件不存在：{value}")
        else:
            from mobile.packaging.android_kit.common import is_64bit_wheel_name

            if not is_64bit_wheel_name(Path(value).name):
                problems.append(f"[android] {key} 不是 64 位 Android wheel：{Path(value).name}")

    official = default_spec_keys()
    if official:
        for section, keys in official.items():
            if section not in values:
                continue  # 未使用的节可以省略
            unknown = [key for key in values[section] if key not in keys]
            for key in unknown:
                if f"{section}.{key}" not in _OVERRIDABLE:
                    problems.append(f"[{section}] 存在官方 default.spec 未定义的键：{key}")
    return problems
