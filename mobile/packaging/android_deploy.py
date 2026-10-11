"""把移动端界面打包成 **64 位** Android APK。

打包链路由 Qt 官方 ``pyside6-android-deploy`` 驱动（内部使用 buildozer /
python-for-android）。本脚本补齐官方工具没有自动化的部分：

1. **精简 staging**：只把运行时需要的 ``mobile`` 子集拷进 ``build/android/project``，
   避免把 ``venv/``、``dist/``、演示文稿等无关内容打进 APK；
2. **Android wheel 解析**：从 Qt 官方下载站（PyPI 上没有 Android wheel）挑选与宿主
   PySide6 版本一致的 64 位 wheel（``android_aarch64`` / ``android_x86_64``）并缓存；
3. **生成 ``pysidedeploy.spec``**：按官方 ``default.spec`` 的键集合写入 staging 目录；
4. **只允许 64 位**：``armeabi-v7a`` / ``x86`` 等 32 位 ABI 与 wheel 一律拒绝。

用法（真实构建需在 Linux / macOS 主机上执行）::

    python -m mobile.packaging.android_deploy --list          # 查看可用的 64 位 wheel
    python -m mobile.packaging.android_deploy --check         # 只做本地校验（任何平台可用）
    python -m mobile.packaging.android_deploy --arch aarch64 --mode debug
    python -m mobile.packaging.android_deploy --print-only    # 只打印将执行的命令

产物：``build/android/dist/<应用名>.apk``（``--mode release`` 时为 ``.aab``）。
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional

from mobile.packaging.android_kit import spec as spec_mod
from mobile.packaging.android_kit import wheels as wheels_mod
from mobile.packaging.android_kit.common import (
    ARCHITECTURES,
    BUILD_ROOT,
    OUTPUT_DIRNAME,
    WHEEL_CACHE_DIRNAME,
    is_64bit_host,
    is_unix_host,
)
from mobile.packaging.android_kit.staging import stage_project

#: Android NDK 版本（Qt 文档要求 r28c：首个默认 16 KB 页对齐的 NDK，Android 15+ 必需）。
REQUIRED_NDK = "28.2.13676358"
#: Android SDK 组件（Qt 文档要求）。
REQUIRED_SDK_COMPONENTS = ("platform-tools", "platforms;android-35", "build-tools;35.0.0")

DEPLOY_ENTRYPOINT = "pyside6-android-deploy"


def log(message: str) -> None:
    print(f"[android-deploy] {message}", flush=True)


def deploy_command(spec_path: Path, overrides: Optional[List[str]] = None) -> List[str]:
    """构造调用官方 ``pyside6-android-deploy`` 的命令。

    ``-c/--config-file`` 与 ``--force`` 均为官方 ``add_deploy_arguments`` 提供的参数；
    ``--force`` 关闭交互式提问，保证在 CI 中不会卡住。
    """
    return [DEPLOY_ENTRYPOINT, "--config-file", str(spec_path), "--force"] + list(overrides or [])


def find_deploy_entrypoint() -> Optional[str]:
    """查找官方部署工具；Windows 上固定返回 ``None``（官方仅支持 Unix 主机）。"""
    if not is_unix_host():
        return None
    found = shutil.which(DEPLOY_ENTRYPOINT)
    if found:
        return found
    candidate = Path(sys.executable).parent / DEPLOY_ENTRYPOINT
    return str(candidate) if candidate.is_file() else None


def check_environment(arch: str) -> List[str]:
    """阻塞**真实构建**的问题列表（空列表表示环境就绪）。

    注意：这里只检查与构建能力相关的条件，不检查 staging / wheel / spec 的配置
    正确性——后者由 :func:`prepare` 与 ``validate_spec`` 负责，因此在 Windows 上
    依然可以用 ``--check`` 验证打包配置本身。
    """
    problems: List[str] = []
    if arch not in ARCHITECTURES:
        problems.append(f"不支持的 ABI：{arch}（仅支持 64 位：{sorted(ARCHITECTURES)}）")
    if not is_64bit_host():
        problems.append("宿主 Python 为 32 位；Qt6 / PySide6 只提供 64 位运行环境，请改用 64 位解释器。")
    if not is_unix_host():
        problems.append(
            "pyside6-android-deploy 只能在 Unix（Linux / macOS）主机上运行，当前是 Windows。"
            "可改用 WSL2 / Linux 主机，或使用仓库内的 GitHub Actions 工作流（.github/workflows/build-android-apk.yml）。"
        )
    elif find_deploy_entrypoint() is None:
        problems.append(f"未找到 {DEPLOY_ENTRYPOINT}；在 Linux/macOS 上执行 pip install PySide6 即会提供该命令。")
    if wheels_mod.host_pyside_version() is None:
        problems.append("未检测到 PySide6，请先安装：pip install -r mobile/requirements-mobile.txt")
    return problems


def prepare(
    arch: str = "aarch64",
    mode: str = "debug",
    title: str = "FastGuard",
    build_root: Path = BUILD_ROOT,
    version: Optional[str] = None,
    download: bool = True,
    ndk_path: str = "",
    sdk_path: str = "",
    recipe_dir: str = "",
    jars_dir: str = "",
    per_package_html: Optional[Dict[str, str]] = None,
) -> Dict[str, object]:
    """完成 staging / wheel 解析 / spec 生成，返回构建上下文。

    不做平台校验，也不调用官方工具，因此可在任意平台（含 Windows）上做单元测试；
    ``per_package_html`` 用于在测试中注入目录列表、避免访问网络。
    """
    build_root = Path(build_root)
    wheel_cache = build_root / WHEEL_CACHE_DIRNAME
    output_dir = build_root / OUTPUT_DIRNAME

    project_dir = stage_project(build_root)
    pyside_wheel, shiboken_wheel, notes = wheels_mod.resolve_wheels(
        wheel_cache,
        arch=arch,
        version=version,
        per_package_html=per_package_html,
        download=download,
    )
    for note in notes:
        log(note)

    if pyside_wheel is None or shiboken_wheel is None:
        missing = [
            name
            for name, path in (("wheel_pyside", pyside_wheel), ("wheel_shiboken", shiboken_wheel))
            if path is None
        ]
        raise FileNotFoundError(
            f"缺少 64 位 Android wheel：{', '.join(missing)}。"
            f"请确认 ABI 与 PySide6 版本（abi={arch}，宿主版本={version or wheels_mod.host_pyside_version()}）。"
        )

    spec_path = project_dir / spec_mod.SPEC_FILENAME
    spec_mod.write_spec(
        spec_path,
        spec_mod.build_spec_text(
            project_dir=project_dir,
            exec_directory=output_dir,
            wheel_pyside=pyside_wheel,
            wheel_shiboken=shiboken_wheel,
            title=title,
            mode=mode,
            arch=arch,
            ndk_path=ndk_path,
            sdk_path=sdk_path,
            recipe_dir=recipe_dir,
            jars_dir=jars_dir,
        ),
    )
    return {
        "build_root": build_root,
        "project_dir": project_dir,
        "wheel_cache": wheel_cache,
        "output_dir": output_dir,
        "spec_path": spec_path,
        "wheel_pyside": pyside_wheel,
        "wheel_shiboken": shiboken_wheel,
        "arch": arch,
        "mode": mode,
        "title": title,
        "notes": notes,
    }


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="打包 FastGuard 移动端界面为 64 位 Android APK（arm64-v8a / x86_64）"
    )
    parser.add_argument(
        "--arch",
        default="aarch64",
        choices=sorted(ARCHITECTURES),
        help="目标 ABI（默认 aarch64 = arm64-v8a 真机；x86_64 = 64 位模拟器）",
    )
    parser.add_argument(
        "--mode",
        default="debug",
        choices=("debug", "release"),
        help="debug 生成 .apk（可直接安装），release 生成 .aab（用于上架）",
    )
    parser.add_argument("--title", default="FastGuard", help="应用名称")
    parser.add_argument("--build-root", default=str(BUILD_ROOT), help="构建目录（默认 build/android）")
    parser.add_argument("--version", default=None, help="Android wheel 版本（默认与宿主 PySide6 一致）")
    parser.add_argument("--no-download", action="store_true", help="不下载 wheel，仅使用本地缓存")
    parser.add_argument("--ndk-path", default="", help="Android NDK 路径（默认使用 buildozer 下载的）")
    parser.add_argument("--sdk-path", default="", help="Android SDK 路径（默认使用 buildozer 下载的）")
    parser.add_argument(
        "--recipe-dir",
        default="",
        help="PySide6 / shiboken6 的 buildozer recipe 目录（默认留空由官方工具决定）",
    )
    parser.add_argument("--jars-dir", default="", help="需要随应用加载的 Qt Android .jar 目录")
    parser.add_argument(
        "--deploy-arg",
        dest="deploy_args",
        action="append",
        default=[],
        metavar="ARG",
        help="透传给官方 pyside6-android-deploy 的附加参数，可重复；"
             "参数以 - 开头时请用等号形式，例如 --deploy-arg=--verbose",
    )
    parser.add_argument("--list", action="store_true", help="列出 Qt 官方站点上可用的 64 位 Android wheel")
    parser.add_argument("--check", action="store_true", help="只做本地校验与 staging，不执行真实构建")
    parser.add_argument("--print-only", action="store_true", help="只打印将执行的命令")
    parser.add_argument("--clean", action="store_true", help="构建前清空构建目录")
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv)

    if args.list:
        return _list_wheels(args.arch)

    build_root = Path(args.build_root)
    if args.clean and build_root.exists():
        log(f"清空构建目录 {build_root}")
        shutil.rmtree(build_root)

    log(f"目标 ABI：{args.arch}（{ARCHITECTURES[args.arch]['android_abi']}），产物模式：{args.mode}")
    log(f"要求 NDK：{REQUIRED_NDK}；要求 SDK 组件：{', '.join(REQUIRED_SDK_COMPONENTS)}")

    # --check / --print-only：先验证打包配置（staging / wheel / spec），再报告环境阻塞项。
    if args.check or args.print_only:
        try:
            context = prepare(
                arch=args.arch,
                mode=args.mode,
                title=args.title,
                build_root=build_root,
                version=args.version,
                download=not args.no_download,
                ndk_path=args.ndk_path,
                sdk_path=args.sdk_path,
                recipe_dir=args.recipe_dir,
                jars_dir=args.jars_dir,
            )
        except (FileNotFoundError, ValueError, RuntimeError) as exc:
            log(f"打包配置校验失败：{exc}")
            return 2

        problems = spec_mod.validate_spec(context["spec_path"])
        for problem in problems:
            log(f"spec 校验失败：{problem}")
        if problems:
            return 2

        log(f"staging 目录：{context['project_dir']}")
        log(f"PySide6 wheel：{Path(context['wheel_pyside']).name}")
        log(f"shiboken6 wheel：{Path(context['wheel_shiboken']).name}")
        log(f"spec：{context['spec_path']}（已通过校验）")
        log("staging 内容：" + ", ".join(sorted(
            str(path.relative_to(context["project_dir"])).replace("\\", "/")
            for path in Path(context["project_dir"]).rglob("*")
            if path.is_file()
        )))

        blockers = check_environment(args.arch)
        for blocker in blockers:
            log(f"环境提示（不影响本次配置校验）：{blocker}")
        if not blockers:
            log("环境就绪，可以执行真实构建")
        if args.print_only:
            log("将执行：" + " ".join(deploy_command(Path(context["spec_path"]), _extra_deploy_args(args))))
        else:
            log("本地校验完成（--check 不执行真实构建）")
        return 0

    problems = check_environment(args.arch)
    if problems:
        for problem in problems:
            log(f"无法构建：{problem}")
        return 2

    try:
        context = prepare(
            arch=args.arch,
            mode=args.mode,
            title=args.title,
            build_root=build_root,
            version=args.version,
            download=not args.no_download,
            ndk_path=args.ndk_path,
            sdk_path=args.sdk_path,
            recipe_dir=args.recipe_dir,
            jars_dir=args.jars_dir,
        )
    except FileNotFoundError as exc:
        log(str(exc))
        return 2
    except ValueError as exc:
        log(f"参数错误：{exc}")
        return 2

    spec_problems = spec_mod.validate_spec(context["spec_path"])
    if spec_problems:
        for problem in spec_problems:
            log(f"spec 校验失败：{problem}")
        return 2

    log(f"staging 目录：{context['project_dir']}")
    log(f"PySide6 wheel：{Path(context['wheel_pyside']).name}")
    log(f"shiboken6 wheel：{Path(context['wheel_shiboken']).name}")
    log(f"spec：{context['spec_path']}")

    command = deploy_command(context["spec_path"], _extra_deploy_args(args))
    log("执行：" + " ".join(command))
    return subprocess.call(command)


def _extra_deploy_args(args: argparse.Namespace) -> List[str]:
    """把 ``--deploy-arg`` 收集到的附加参数展开为列表。"""
    raw = getattr(args, "deploy_args", None) or []
    if isinstance(raw, str):  # 兼容旧式写法
        raw = raw.split()
    return [str(item) for item in raw if str(item).strip()]


def _list_wheels(arch: str) -> int:
    host_version = wheels_mod.host_pyside_version()
    log(f"宿主 PySide6 版本：{host_version or '未安装'}；查询 ABI：{arch}")
    try:
        available = wheels_mod.available_64bit_wheels(arch)
    except Exception as exc:
        log(f"查询失败：{exc}")
        return 2
    for package, names in available.items():
        log(f"{package}：{len(names)} 个 64 位 wheel")
        for name in names[-6:]:
            marker = "  <- 与宿主版本一致" if host_version and wheels_mod.wheel_version(name) == host_version else ""
            log(f"    {name}{marker}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
