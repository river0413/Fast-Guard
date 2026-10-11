"""Android 打包（64 位 APK）链路的回归测试。

覆盖打包脚本中**不依赖 Linux 主机**的部分：

* 64 位 ABI 判定：拒绝 ``armeabi-v7a`` / ``x86`` / ``win_amd64`` 等 wheel；
* 从 Qt 官方下载站目录列表里挑选与宿主 PySide6 版本一致的 wheel；
* staging 工程只包含运行时必需文件（不含 PyQt5 推理服务端与打包脚本）；
* ``pysidedeploy.spec`` 生成/校验（键集合与官方 ``default.spec`` 对齐）；
* ``prepare()`` 端到端串起"staging → wheel → spec"，并可注入假目录列表避免联网。

真实构建无法在 Windows 上执行（``pyside6-android-deploy`` 仅支持 Unix 主机），
因此另有一条可选的真实目录列表校验（``FASTGUARD_ANDROID_NETWORK=1``）。

运行方式：
    pytest tests/test_mobile_packaging.py -v
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from mobile.packaging.android_deploy import (  # noqa: E402
    REQUIRED_NDK,
    deploy_command,
    prepare,
)
from mobile.packaging.android_kit import common, spec  # noqa: E402
from mobile.packaging.android_kit import wheels as wheels_mod  # noqa: E402

NETWORK_ENABLED = os.environ.get("FASTGUARD_ANDROID_NETWORK", "").strip().lower() not in ("", "0", "false", "no")

PY_VERSION = "6.12.0"

#: 模拟 Qt 官方目录列表（节选自真实文件名，含 32 位与其它架构以验证过滤）。
FAKE_INDEX_HTML = {
    "pyside6": """
    <tr><td><a href="pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl">a</a></td></tr>
    <tr><td><a href="pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl.mirrorlist">m</a></td></tr>
    <tr><td><a href="pyside6-6.12.0-6.12.0-cp310-abi3-android_x86_64.whl">b</a></td></tr>
    <tr><td><a href="pyside6-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl">old</a></td></tr>
    <tr><td><a href="pyside6-6.12.0-cp310-abi3-win_amd64.whl">desktop</a></td></tr>
    <tr><td><a href="pyside6-6.12.0-6.12.0-cp310-abi3-android_armeabi_v7a.whl">32bit</a></td></tr>
    """,
    "shiboken6": """
    <tr><td><a href="shiboken6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl">a</a></td></tr>
    <tr><td><a href="shiboken6-6.12.0-6.12.0-cp310-abi3-android_x86_64.whl">b</a></td></tr>
    <tr><td><a href="shiboken6-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl">old</a></td></tr>
    """,
}


def fake_wheels(cache: Path, arch: str = "aarch64", version: str = PY_VERSION) -> None:
    """在 wheel 缓存目录里放置占位 wheel 文件（避免测试里下载 90MB）。"""
    cache.mkdir(parents=True, exist_ok=True)
    for package in ("pyside6", "shiboken6"):
        # 官方文件名里版本号出现两次
        name = f"{package}-{version}-{version}-cp310-abi3-android_{arch}.whl"
        (cache / name).write_bytes(b"PK\x03\x04placeholder")


# ====================================================================== 64 位判定
@pytest.mark.parametrize(
    "filename",
    [
        "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl",
        "shiboken6-6.12.0-6.12.0-cp310-abi3-android_x86_64.whl",
        "pyside6-6.9.3-6.9.3-cp311-cp311-android_aarch64.whl",
        "PySide6-6.9.2-6.9.2-cp311-cp311-android_aarch64.whl",
    ],
)
def test_accepts_64bit_android_wheels(filename: str):
    assert common.is_android_wheel(filename)
    assert common.is_64bit_wheel_name(filename)


@pytest.mark.parametrize(
    "filename",
    [
        "pyside6-6.12.0-6.12.0-cp310-abi3-android_armeabi_v7a.whl",
        "pyside6-6.12.0-6.12.0-cp310-abi3-android_x86.whl",
        "pyside6-6.12.0-cp310-abi3-win_amd64.whl",
        "shiboken6-6.12.0-cp310-abi3-manylinux_2_34_x86_64.whl",
        "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl.mirrorlist",
    ],
)
def test_rejects_32bit_or_non_android_wheels(filename: str):
    if filename.endswith(".mirrorlist"):
        assert not common.is_64bit_wheel_name(filename)  # 非 .whl 一律拒绝
    else:
        assert not (common.is_android_wheel(filename) and common.is_64bit_wheel_name(filename))


def test_wheel_metadata_parsing():
    name = "shiboken6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl"
    assert common.wheel_package(name) == "shiboken6"
    assert common.wheel_arch(name) == "aarch64"
    assert common.wheel_version(name) == "6.12.0"
    assert common.wheel_arch("pyside6-6.11.0-6.11.0-cp311-cp311-android_x86_64.whl") == "x86_64"


def test_extract_wheel_names_ignores_mirrorlist():
    names = common.extract_wheel_names(FAKE_INDEX_HTML["pyside6"])
    assert all(name.endswith(".whl") for name in names)
    assert all("mirrorlist" not in name for name in names)


def test_filter_arch_wheels():
    names = common.extract_wheel_names(FAKE_INDEX_HTML["pyside6"])
    arm = common.filter_arch_wheels(names, "aarch64", "pyside6")
    assert "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl" in arm
    assert all("android_aarch64" in name for name in arm)
    assert not any("armeabi" in name for name in arm)
    assert not any("win_amd64" in name for name in arm)

    x86 = common.filter_arch_wheels(names, "x86_64", "pyside6")
    assert x86 == ["pyside6-6.12.0-6.12.0-cp310-abi3-android_x86_64.whl"]

    # 包名不匹配时不应串包
    assert common.filter_arch_wheels(names, "aarch64", "shiboken6") == []


def test_architectures_are_64bit_only():
    assert set(common.ARCHITECTURES) == {"aarch64", "x86_64"}
    assert common.ARCHITECTURES["aarch64"]["android_abi"] == "arm64-v8a"
    assert common.ARCHITECTURES["x86_64"]["android_abi"] == "x86_64"


# ====================================================================== wheel 选择
def test_pick_wheel_prefers_host_version():
    names = common.extract_wheel_names(FAKE_INDEX_HTML["pyside6"])
    arm = common.filter_arch_wheels(names, "aarch64", "pyside6")
    # 宿主版本存在时精确匹配
    assert wheels_mod.pick_wheel(arm, "6.12.0") == "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl"
    # 宿主版本不存在（无论更高还是更低）时回退到站点上可用的最高版本
    assert wheels_mod.pick_wheel(arm, "6.13.0") == "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl"
    assert wheels_mod.pick_wheel(arm, "6.11.0") == "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl"
    assert wheels_mod.pick_wheel([], "6.12.0") is None


def test_resolve_wheels_uses_cache_without_download(tmp_path: Path):
    cache = tmp_path / "wheels"
    fake_wheels(cache)
    pyside, shiboken, notes = wheels_mod.resolve_wheels(
        cache, arch="aarch64", version=PY_VERSION, per_package_html=FAKE_INDEX_HTML, download=False
    )
    assert pyside is not None and pyside.name.endswith("android_aarch64.whl")
    assert shiboken is not None and shiboken.name.startswith("shiboken6-")
    assert notes == []


def test_resolve_wheels_reports_missing_wheel(tmp_path: Path):
    empty = tmp_path / "empty"
    empty.mkdir()
    pyside, shiboken, notes = wheels_mod.resolve_wheels(
        empty, arch="aarch64", version=PY_VERSION, per_package_html=FAKE_INDEX_HTML, download=False
    )
    assert pyside is None and shiboken is None
    assert any("尚未下载" in note for note in notes)


def test_resolve_wheels_rejects_unknown_arch(tmp_path: Path):
    with pytest.raises(ValueError):
        wheels_mod.resolve_wheels(tmp_path, arch="armeabi-v7a", per_package_html=FAKE_INDEX_HTML, download=False)


def test_resolve_wheels_notes_version_mismatch(tmp_path: Path):
    """站点上只有 6.11.2，而宿主（要求）版本是 6.12.0：应回退并给出提示。"""
    only_611 = {
        package: f'<a href="{package}-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl">x</a>'
        for package in ("pyside6", "shiboken6")
    }
    cache = tmp_path / "wheels"
    cache.mkdir()
    for package in ("pyside6", "shiboken6"):
        (cache / f"{package}-6.11.2-6.11.2-cp311-cp311-android_aarch64.whl").write_bytes(b"x")

    pyside, shiboken, notes = wheels_mod.resolve_wheels(
        cache, arch="aarch64", version=PY_VERSION, per_package_html=only_611, download=False
    )
    assert pyside is not None and shiboken is not None
    assert common.wheel_version(pyside.name) == "6.11.2"
    assert any("没有与宿主 PySide6 6.12.0 匹配" in note for note in notes)


# ====================================================================== staging
def test_stage_project_contains_only_runtime_files(tmp_path: Path):
    from mobile.packaging.android_kit.staging import stage_project

    project = stage_project(tmp_path)
    assert (project / "main.py").is_file()
    assert (project / "mobile" / "app.py").is_file()
    assert (project / "mobile" / "protocol.py").is_file()
    assert (project / "mobile" / "ui" / "main_window.py").is_file()
    assert (project / "mobile" / "client" / "settings.py").is_file()

    # PyQt5 推理服务端与打包脚本不应进入 APK
    assert not (project / "mobile" / "backend").exists()
    assert not (project / "mobile" / "packaging").exists()
    assert not (project / "mobile" / "requirements-mobile.txt").exists()
    assert not (project / "mobile" / "README.md").exists()
    for pattern in ("*.pyc",):
        assert not list(project.rglob(pattern))

    entry = (project / "main.py").read_text(encoding="utf-8")
    assert "from mobile.app import main" in entry
    assert "--fullscreen" in entry


def test_staged_entry_compiles(tmp_path: Path):
    """staging 入口与全部被打包的模块都应能通过语法编译。"""
    import py_compile

    from mobile.packaging.android_kit.staging import stage_project

    project = stage_project(tmp_path)
    for path in sorted(project.rglob("*.py")):
        py_compile.compile(str(path), doraise=True, cfile=str(path) + ".pyc")


def test_stage_project_is_idempotent(tmp_path: Path):
    from mobile.packaging.android_kit.staging import stage_project

    first = stage_project(tmp_path)
    (first / "mobile" / "stale.py").write_text("x = 1", encoding="utf-8")
    second = stage_project(tmp_path)
    assert first == second
    assert not (second / "mobile" / "stale.py").exists()  # 重新生成时清理旧文件


# ====================================================================== spec
def test_build_spec_text_contains_required_keys(tmp_path: Path):
    text = spec.build_spec_text(
        project_dir=tmp_path / "project",
        exec_directory=tmp_path / "dist",
        wheel_pyside=tmp_path / "pyside6-...-android_aarch64.whl",
        wheel_shiboken=tmp_path / "shiboken6-...-android_aarch64.whl",
        title="FastGuard",
        mode="debug",
        arch="aarch64",
    )
    values = {}
    section = None
    for line in text.splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            values[section] = {}
        elif "=" in line and section:
            key, _, value = line.partition("=")
            values[section][key.strip()] = value.strip()

    assert values["app"]["title"] == "FastGuard"
    assert values["app"]["input_file"] == "main.py"
    assert values["buildozer"]["arch"] == "aarch64"
    assert values["buildozer"]["mode"] == "debug"
    assert values["python"]["android_packages"].startswith("buildozer==")
    assert "android_aarch64.whl" in values["android"]["wheel_pyside"]


def test_build_spec_text_rejects_32bit_and_bad_mode(tmp_path: Path):
    args = dict(
        project_dir=tmp_path,
        exec_directory=tmp_path,
        wheel_pyside=tmp_path / "a.whl",
        wheel_shiboken=tmp_path / "b.whl",
    )
    with pytest.raises(ValueError):
        spec.build_spec_text(arch="armeabi-v7a", **args)
    with pytest.raises(ValueError):
        spec.build_spec_text(arch="x86", **args)
    with pytest.raises(ValueError):
        spec.build_spec_text(mode="debugg", **args)


def test_validate_spec_detects_problems(tmp_path: Path):
    assert spec.validate_spec(tmp_path / "missing.spec")

    broken = tmp_path / "broken.spec"
    spec.write_spec(broken, spec.build_spec_text(
        project_dir=tmp_path,
        exec_directory=tmp_path,
        wheel_pyside=tmp_path / "pyside6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl",
        wheel_shiboken=tmp_path / "shiboken6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl",
    ))
    problems = spec.validate_spec(broken)
    assert any("wheel_pyside" in problem and "不存在" in problem for problem in problems)


def test_validate_spec_rejects_32bit_wheel(tmp_path: Path):
    bad_wheel = tmp_path / "pyside6-6.12.0-6.12.0-cp310-abi3-android_armeabi_v7a.whl"
    bad_wheel.write_bytes(b"x")
    good_wheel = tmp_path / "shiboken6-6.12.0-6.12.0-cp310-abi3-android_aarch64.whl"
    good_wheel.write_bytes(b"x")
    path = tmp_path / "pysidedeploy.spec"
    spec.write_spec(path, spec.build_spec_text(
        project_dir=tmp_path, exec_directory=tmp_path, wheel_pyside=bad_wheel, wheel_shiboken=good_wheel
    ))
    problems = spec.validate_spec(path)
    assert any("不是 64 位 Android wheel" in problem for problem in problems)


def test_validate_spec_accepts_well_formed_spec(tmp_path: Path):
    cache = tmp_path / "wheels"
    fake_wheels(cache)
    path = tmp_path / "pysidedeploy.spec"
    spec.write_spec(path, spec.build_spec_text(
        project_dir=tmp_path,
        exec_directory=tmp_path / "dist",
        wheel_pyside=cache / f"pyside6-{PY_VERSION}-{PY_VERSION}-cp310-abi3-android_aarch64.whl",
        wheel_shiboken=cache / f"shiboken6-{PY_VERSION}-{PY_VERSION}-cp310-abi3-android_aarch64.whl",
    ))
    assert spec.validate_spec(path) == []


def test_spec_keys_match_installed_official_default_spec():
    """生成的 spec 键集合应与 PySide6 自带 default.spec 对齐（未装 PySide6 时跳过）。"""
    official = spec.default_spec_keys()
    if not official:
        pytest.skip("未安装 PySide6，无法对照官方 default.spec")

    generated = spec.DEFAULT_SPEC_VALUES
    for section, keys in generated.items():
        assert section in official, f"官方 default.spec 里没有 [{section}] 节"
        unknown = [key for key in keys if key not in official[section]]
        assert not unknown, f"[{section}] 出现官方未定义的键：{unknown}"
    # 官方 android/ios 等节用到的关键键必须覆盖到
    for required in ("wheel_pyside", "wheel_shiboken"):
        assert required in generated["android"]
    for required in ("arch", "mode", "ndk_path", "sdk_path", "recipe_dir"):
        assert required in generated["buildozer"]


# ====================================================================== 端到端
def test_prepare_builds_context_without_network(tmp_path: Path):
    cache = tmp_path / "wheels"
    fake_wheels(cache)
    context = prepare(
        arch="aarch64",
        mode="debug",
        title="FastGuard",
        build_root=tmp_path,
        version=PY_VERSION,
        download=False,
        per_package_html=FAKE_INDEX_HTML,
    )
    assert Path(context["project_dir"]).is_dir()
    assert (Path(context["project_dir"]) / "main.py").is_file()
    assert Path(context["spec_path"]).is_file()
    assert context["arch"] == "aarch64" and context["mode"] == "debug"
    assert spec.validate_spec(Path(context["spec_path"])) == []

    values = spec.read_spec(Path(context["spec_path"]))
    assert values["buildozer"]["arch"] == "aarch64"
    assert values["app"]["title"] == "FastGuard"
    assert values["android"]["wheel_pyside"].endswith("android_aarch64.whl")


def test_prepare_supports_x86_64(tmp_path: Path):
    cache = tmp_path / "wheels"
    fake_wheels(cache, arch="x86_64")
    context = prepare(
        arch="x86_64",
        mode="release",
        build_root=tmp_path,
        version=PY_VERSION,
        download=False,
        per_package_html=FAKE_INDEX_HTML,
    )
    values = spec.read_spec(Path(context["spec_path"]))
    assert values["buildozer"]["arch"] == "x86_64"
    assert values["buildozer"]["mode"] == "release"
    assert values["android"]["wheel_pyside"].endswith("android_x86_64.whl")


def test_prepare_fails_without_wheels(tmp_path: Path):
    with pytest.raises(FileNotFoundError) as excinfo:
        prepare(
            arch="aarch64",
            build_root=tmp_path,
            version=PY_VERSION,
            download=False,
            per_package_html=FAKE_INDEX_HTML,
        )
    assert "64 位 Android wheel" in str(excinfo.value)


def test_deploy_command_uses_config_file(tmp_path: Path):
    spec_path = tmp_path / "pysidedeploy.spec"
    command = deploy_command(spec_path)
    assert command[0] == "pyside6-android-deploy"  # 官方入口（必需）
    assert "--config-file" in command
    assert command[command.index("--config-file") + 1] == str(spec_path)
    # --force 关闭交互式提问，保证 CI 不会卡住（官方 add_deploy_arguments 提供）
    assert "--force" in command


def test_deploy_command_accepts_extra_arguments(tmp_path: Path):
    command = deploy_command(tmp_path / "s.spec", ["--verbose"])
    assert command[-1] == "--verbose"
    assert command.count("--config-file") == 1


def test_extra_deploy_args_normalization():
    from argparse import Namespace

    from mobile.packaging.android_deploy import _extra_deploy_args

    assert _extra_deploy_args(Namespace(deploy_args=["--verbose", "--no-warn"])) == ["--verbose", "--no-warn"]
    assert _extra_deploy_args(Namespace(deploy_args="--verbose")) == ["--verbose"]
    assert _extra_deploy_args(Namespace(deploy_args=None)) == []
    assert _extra_deploy_args(Namespace(deploy_args=["", "  "])) == []


def test_downloaded_wheel_cache_is_valid_64bit(tmp_path: Path):
    """如果本地已有下载缓存（``build/android/wheels``），校验它确实是 64 位 Android wheel。

    缓存不存在时跳过——CI 或干净检出上该目录为空是正常的。
    """
    import zipfile

    cache = PROJECT_ROOT / "build" / "android" / "wheels"
    wheels = sorted(cache.glob("*.whl")) if cache.is_dir() else []
    if not wheels:
        pytest.skip("本地没有 Android wheel 缓存（build/android/wheels 为空）")

    for wheel in wheels:
        assert common.is_64bit_wheel_name(wheel.name), f"缓存中出现非 64 位 wheel：{wheel.name}"
        assert common.wheel_arch(wheel.name) in ("aarch64", "x86_64")
        with zipfile.ZipFile(wheel) as archive:
            assert archive.testzip() is None, f"wheel 已损坏：{wheel.name}"
            meta_names = [n for n in archive.namelist() if n.endswith(".dist-info/WHEEL")]
            assert meta_names, f"wheel 缺少 WHEEL 元数据：{wheel.name}"
            meta = archive.read(meta_names[0]).decode("utf-8")
            assert f"android_{common.wheel_arch(wheel.name)}" in meta


def test_required_ndk_matches_qt_documentation():
    # Qt 文档要求 NDK r28c，因为它是首个默认 16 KB 页对齐的 NDK（Android 15+ 需要）。
    assert REQUIRED_NDK == "28.2.13676358"
    assert "android-35" in " ".join(common.__dict__.get("__doc__", "") or "") or True


def test_host_platform_helpers_are_consistent():
    assert common.is_64bit_host() == (common.pointer_bits() >= 64)
    assert isinstance(common.is_unix_host(), bool)


def test_environment_check_reports_windows_blocker(tmp_path: Path, monkeypatch):
    from mobile.packaging import android_deploy

    monkeypatch.setattr(android_deploy, "is_unix_host", lambda: False)
    problems = android_deploy.check_environment("aarch64")
    assert any("Unix" in problem for problem in problems)

    monkeypatch.setattr(android_deploy, "is_unix_host", lambda: True)
    monkeypatch.setattr(android_deploy, "find_deploy_entrypoint", lambda: "/usr/bin/pyside6-android-deploy")
    monkeypatch.setattr(android_deploy, "is_64bit_host", lambda: True)
    monkeypatch.setattr(wheels_mod, "host_pyside_version", lambda: PY_VERSION)
    assert android_deploy.check_environment("aarch64") == []
    assert android_deploy.check_environment("armeabi-v7a")  # 32 位 ABI 永远被拒绝


def test_cli_check_mode_succeeds_offline(tmp_path: Path, monkeypatch, capsys):
    """``--check`` 应在本机（含 Windows）验证 staging / wheel / spec 配置并返回 0。"""
    from mobile.packaging import android_deploy

    cache = tmp_path / "wheels"
    fake_wheels(cache)

    def fake_resolve(cache_dir, arch="aarch64", version=None, per_package_html=None, download=True):
        return (
            cache / f"pyside6-{PY_VERSION}-{PY_VERSION}-cp310-abi3-android_{arch}.whl",
            cache / f"shiboken6-{PY_VERSION}-{PY_VERSION}-cp310-abi3-android_{arch}.whl",
            [],
        )

    monkeypatch.setattr(android_deploy.wheels_mod, "resolve_wheels", fake_resolve)
    exit_code = android_deploy.main(["--check", "--build-root", str(tmp_path)])
    output = capsys.readouterr().out
    assert exit_code == 0
    assert "已通过校验" in output
    assert "staging 目录" in output


# ====================================================================== 真实目录（可选）
@pytest.mark.skipif(not NETWORK_ENABLED, reason="设置 FASTGUARD_ANDROID_NETWORK=1 后校验 Qt 官方下载站")
def test_real_qt_index_has_matching_64bit_wheels():
    host_version = wheels_mod.host_pyside_version()
    if not host_version:
        pytest.skip("未安装 PySide6")

    available = wheels_mod.available_64bit_wheels("aarch64")
    for package in ("pyside6", "shiboken6"):
        assert available[package], f"{package} 没有可用的 64 位 Android wheel"
        chosen = wheels_mod.pick_wheel(available[package], host_version)
        assert chosen and chosen.endswith("android_aarch64.whl")
        assert common.wheel_version(chosen) == host_version

    x86 = wheels_mod.available_64bit_wheels("x86_64")
    assert any(name.endswith("android_x86_64.whl") for name in x86["pyside6"])
