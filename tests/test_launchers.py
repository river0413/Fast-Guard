"""启动脚本与依赖清单的回归测试。

对应三个真实踩过的坑：

1. **失效的虚拟环境**：仓库里的 ``venv/`` 是从别的机器拷来的，其
   ``Scripts\\python.exe`` 是死链，直接调用会以
   ``No Python at 'C:\\Users\\<别人>\\...'`` 退出 103。启动脚本必须先验证
   ``venv`` 是否可用，不能"存在就用"。
2. **.bat 里的中文会被 cmd 按 OEM 代码页解码**：在 zh-CN（GBK）下，中文字节
   可能解出 ``|`` ``>`` ``<`` ``)`` 等 cmd 元字符，把脚本"撕"成非法命令；
   ``rem`` 行里的 ``< >`` 还会被当成重定向（rem 不屏蔽重定向）。因此 .bat 必须
   保持纯 ASCII。
3. **同一条 import 里 PyQt5 先于 torch**：实测触发 ``WinError 1114 ... c10.dll``
   （与桌面端 main.py 的加载顺序约束同源），所以依赖探测必须分开执行。

另外确认移动端依赖清单只装 ``PySide6-Essentials``（实测 ``PySide6`` 元包会额外
拉入 Addons / WebEngine / Pdf，多占约 650 MB，界面用不到）。

运行方式：
    pytest tests/test_launchers.py -v
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

PROJECT_ROOT = Path(__file__).resolve().parent.parent

MOBILE_LAUNCHER = PROJECT_ROOT / "mobile" / "run_mobile.bat"
DESKTOP_LAUNCHER = PROJECT_ROOT / "run_fastguard.bat"
MOBILE_REQUIREMENTS = PROJECT_ROOT / "mobile" / "requirements-mobile.txt"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


@pytest.fixture(params=[MOBILE_LAUNCHER, DESKTOP_LAUNCHER], ids=["mobile", "desktop"])
def launcher(request) -> Path:
    path: Path = request.param
    assert path.is_file(), f"启动脚本不存在：{path}"
    return path


# ====================================================================== 编码安全
def test_batch_files_are_pure_ascii(launcher: Path):
    """必须是纯 ASCII。

    中文在 GBK 下会被解码成含 ``|`` / ``>`` / ``)`` 的字节序列，导致 cmd 报
    "'xxx' is not recognized as an internal or external command"。实测已复现过，
    因此这里直接锁死：不允许任何非 ASCII 字节。
    """
    raw = launcher.read_bytes()
    offenders = [(index, byte) for index, byte in enumerate(raw) if byte > 127]
    assert not offenders, f"{launcher.name} 含非 ASCII 字节（前几处：{offenders[:5]}）"


def test_batch_files_have_no_bom(launcher: Path):
    raw = launcher.read_bytes()
    assert not raw.startswith(b"\xef\xbb\xbf"), f"{launcher.name} 不应带 UTF-8 BOM"


def test_batch_files_use_crlf(launcher: Path):
    """Windows 批处理按 CRLF 换行更稳妥（LF-only 在部分场景会出问题）。"""
    raw = launcher.read_bytes()
    bare_lf = raw.count(b"\n") - raw.count(b"\r\n")
    assert bare_lf == 0, f"{launcher.name} 存在 {bare_lf} 个裸 LF 换行"


def test_rem_lines_do_not_contain_redirection(launcher: Path):
    """``rem`` 行里的 < > 仍会被 cmd 当作重定向。"""
    for lineno, line in enumerate(read(launcher).splitlines(), start=1):
        stripped = line.strip()
        if not stripped.lower().startswith("rem"):
            continue
        assert not re.search(r"[<>]", stripped), (
            f"{launcher.name}:{lineno} 的 rem 行含 < 或 >，cmd 会当成重定向：{stripped[:60]}"
        )


def test_no_chcp_needed(launcher: Path):
    """保持纯 ASCII 后不应再依赖 chcp 切换代码页。"""
    assert "chcp" not in read(launcher).lower()


# ====================================================================== 失效 venv
def test_launcher_validates_venv_before_using_it(launcher: Path):
    """存在 venv 时必须先探测可用性，不能直接调用它的 python.exe。"""
    text = read(launcher)

    assert re.search(r'"venv\\Scripts\\python\.exe"\s+-c\s+"', text), (
        f"{launcher.name} 未对 venv 解释器做可用性探测"
    )

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.lower().startswith("rem") or '"venv\\Scripts\\python.exe"' not in stripped:
            continue
        # 允许： -c "..." 探测、set "PYCMD=..." 赋值、call :try_candidate ...
        assert (
            '-c "' in stripped
            or stripped.startswith("set ")
            or stripped.startswith("call ")
            or stripped.startswith("if ")
        ), f"{launcher.name} 疑似无条件使用 venv 解释器：{stripped}"


def test_launcher_warns_about_broken_venv(launcher: Path):
    """失效的 venv 应给出可见提示，而不是静默地报一堆 No Python at ...。"""
    text = read(launcher)
    assert "errorlevel 1" in text
    lowered = text.lower()
    assert "unusable" in lowered or "broken" in lowered


def test_launcher_has_64bit_guard(launcher: Path):
    """Qt6 / PyQt5 都要求 64 位解释器，脚本需要显式校验。"""
    assert "struct.calcsize('P')" in read(launcher), f"{launcher.name} 缺少 64 位校验"


def test_launcher_has_fallback_chain(launcher: Path):
    """需要多级回退：venv → .venv → 系统解释器。"""
    text = read(launcher)
    for token in ("call :try_candidate", ":try_candidate", ":finalize"):
        assert token in text, f"{launcher.name} 缺少 {token}"
    assert "-3.10" in text and '".venv\\Scripts\\python.exe"' in text


def test_launcher_handles_missing_python_gracefully(launcher: Path):
    text = read(launcher)
    assert "no usable 64-bit Python interpreter" in text
    assert "pause" in text  # 双击运行时不要一闪而过


# ====================================================================== import 顺序
def test_desktop_launcher_checks_imports_separately():
    """实测：`import PyQt5, ultralytics` 会触发 c10.dll 的 WinError 1114。"""
    text = read(DESKTOP_LAUNCHER)

    combined = re.findall(r'-c\s+"import\s+[^"]*,[^"]*"', text)
    offenders = [item for item in combined if "PyQt5" in item and "ultralytics" in item]
    assert not offenders, f"存在把 PyQt5 与 ultralytics 放在同一条 import 的写法：{offenders}"

    assert re.search(r'-c\s+"import ultralytics"', text), "缺少 ultralytics 探测"
    assert re.search(r'-c\s+"import PyQt5"', text), "缺少 PyQt5 探测"


def test_mobile_launcher_probes_pyside_and_requirements():
    text = read(MOBILE_LAUNCHER)
    assert "import PySide6.QtWidgets" in text
    assert "requirements-mobile.txt" in text
    # 已装好 Qt6 的解释器应被优先选中，避免重复下载几百 MB
    assert "HAVE_PYSIDE" in text


# ====================================================================== 依赖清单
def test_mobile_requirements_pins_essentials_only():
    """只装 Essentials：PySide6 元包会多拉约 650 MB 的 Addons/WebEngine/Pdf。"""
    lines = [
        line.strip()
        for line in read(MOBILE_REQUIREMENTS).splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    assert any(line.startswith("PySide6-Essentials") for line in lines), lines

    fat = [line for line in lines if re.match(r"^PySide6(?![-_])", line)]
    assert not fat, f"依赖清单里出现了 PySide6 元包，会额外拉入 Addons/WebEngine/Pdf：{fat}"


def test_mobile_requirements_does_not_pin_android_deploy():
    """pyside6-android-deploy 不在 PyPI 上，不能写进依赖清单（会装失败）。"""
    for line in read(MOBILE_REQUIREMENTS).splitlines():
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        assert "android-deploy" not in stripped


def test_desktop_requirements_untouched():
    """桌面端依赖清单仍为 PyQt5 阵营，未混入移动端的 Qt6 依赖。"""
    text = read(PROJECT_ROOT / "requirements.txt")
    assert "PyQt5" in text
    assert "PySide6" not in text
