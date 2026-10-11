#!/usr/bin/env bash
# FastGuard 移动端 —— 64 位 Android APK 一键打包脚本（Linux / macOS）
#
# Windows 上无法运行 pyside6-android-deploy（官方限制），请改用：
#   * WSL2 / Linux 主机 执行本脚本；
#   * 或使用仓库内的 GitHub Actions 工作流 .github/workflows/build-android-apk.yml
#
# 用法：
#   ./mobile/build_android_apk.sh                 # arm64-v8a 真机，生成 .apk
#   ./mobile/build_android_apk.sh --arch x86_64   # 64 位模拟器
#   ./mobile/build_android_apk.sh --mode release  # 生成 .aab（上架用）
#   ./mobile/build_android_apk.sh --check         # 只校验配置，不真正构建
#
# 首次运行会自动下载 Android NDK r28c 与 SDK（约数 GB，耗时较长）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
ANDROID_CACHE="${HOME}/.pyside6-android-deploy"

# 只校验配置（允许 --check 出现在任意位置）
ONLY_CHECK=0
for arg in "$@"; do
  if [[ "${arg}" == "--check" ]]; then
    ONLY_CHECK=1
  fi
done

log() { printf '[build-apk] %s\n' "$*"; }
die() { printf '[build-apk][错误] %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 前置检查
if [[ "$(uname -s)" == "Darwin" || "$(uname -s)" == "Linux" ]]; then
  :
else
  die "本脚本仅支持 Linux / macOS（pyside6-android-deploy 的官方限制）"
fi

"${PYTHON_BIN}" - <<'PY' || die "需要 64 位 Python 3.10+"
import struct, sys
assert sys.version_info >= (3, 10), sys.version
assert struct.calcsize("P") * 8 >= 64, "32 位解释器不受支持"
PY

command -v java >/dev/null 2>&1 || die "未找到 JDK；buildozer/Gradle 需要 JDK 17+"
java -version 2>&1 | head -n 1 | grep -qE '"(1\.)?1[7-9]|2[0-9]' || log "提示：建议使用 JDK 17 或更高版本"

# ---------------------------------------------------------------- 依赖安装
"${PYTHON_BIN}" -m pip install --upgrade pip >/dev/null
if ! "${PYTHON_BIN}" -c "import PySide6" >/dev/null 2>&1; then
  log "安装 PySide6（会同时提供 pyside6-android-deploy）"
  "${PYTHON_BIN}" -m pip install -r mobile/requirements-mobile.txt
fi

if ! command -v pyside6-android-deploy >/dev/null 2>&1; then
  die "未找到 pyside6-android-deploy；请先 pip install PySide6（Unix 上才提供该命令）"
fi

log "安装 Android 打包依赖（buildozer / cython）"
"${PYTHON_BIN}" -m pip install "buildozer==1.6.0" "cython==0.29.33" pyyaml >/dev/null

# ---------------------------------------------------------------- NDK / SDK
if [[ ! -d "${ANDROID_CACHE}" ]]; then
  log "首次运行：下载 Android NDK r28c 与 SDK 到 ${ANDROID_CACHE}（耗时较长）"
  TEMP_SETUP="$(mktemp -d)"
  git clone --depth 1 https://code.qt.io/pyside/pyside-setup.git "${TEMP_SETUP}" >/dev/null
  "${PYTHON_BIN}" "${TEMP_SETUP}/tools/cross_compile_android/main.py" \
    --download-only --skip-update --auto-accept-license
  rm -rf "${TEMP_SETUP}"
fi

# ---------------------------------------------------------------- 构建
log "校验打包配置"
"${PYTHON_BIN}" -m mobile.packaging.android_deploy "$@" --check

if (( ONLY_CHECK )); then
  log "仅校验配置，结束"
  exit 0
fi

log "开始构建（首次会编译 Qt for Python，可能需要 30～60 分钟）"
"${PYTHON_BIN}" -m mobile.packaging.android_deploy "$@"

log "完成。产物位置："
find . -name "*.apk" -o -name "*.aab" | sed 's/^/  /' || true
log "安装到手机：adb install -r <apk 路径>"
