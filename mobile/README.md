# FastGuard 移动端界面（Qt6 / PySide6）

面向手机形态的 FastGuard 客户端界面：**推理仍在车机 / PC 上完成，手机只负责显示推理画面与下发参数**，
这就是界面右上角"卸载推理"徽标的含义。

| 设计要求 | 实现位置 |
|---|---|
| 只保留 AI 推理画面（省略预处理画面） | `mobile/ui/video_view.py`、`mobile/backend/engine_bridge.py` |
| 不显示帧率，也不显示"稳定性"指标 | `mobile/backend/engine_bridge.py`（状态中不含 `fps`）、`mobile/ui/overlay.py` |
| 右上角"卸载推理"徽标 | `mobile/ui/overlay.py` → `OffloadBadge` |
| 左上角汉堡设置栏 | `mobile/ui/overlay.py` → `HamburgerButton`、`mobile/ui/drawer.py` |
| 切换摄像头 / 阈值设置 / 推理图片大小设置 | `mobile/ui/drawer.py` + `mobile/protocol.py` + `core/video_thread.py` |
| 64 位支持 | `mobile/packaging/android_deploy.py`（仅 arm64-v8a / x86_64） |

---

## 1. 架构：架构不变，只加一层"画面搬运"

```
┌────────────────────────── 车机 / PC（推理侧，架构不变） ──────────────────────────┐
│  core/video_thread.py · VideoThread   ← 视频读取 / 预处理 / YOLO / 风险分析 全沿用 │
│            │ frame_signal(原始, 预处理, 推理, BEV)                                │
│            ▼                                                                      │
│  mobile/backend/engine_bridge.py   ← 丢弃"预处理"画面，只保留推理画面 + 精简状态   │
│            ▼                                                                      │
│  mobile/backend/frame_hub.py       ← 只留最新一帧，单次 JPEG 编码，多客户端复用    │
│            ▼                                                                      │
│  mobile/backend/frame_server.py    ← TCP + 二进制分帧（mobile/protocol.py）        │
└───────────────────────────────────┬───────────────────────────────────────────────┘
                                    │ 127.0.0.1 / 局域网 Wi-Fi
┌───────────────────────────────────▼───────────────────────────────────────────────┐
│  手机（Qt6 / PySide6，不含推理）                                                   │
│  mobile/client/transport.py  FrameClient（接收线程 + 指令队列）                     │
│  mobile/ui/main_window.py    满屏推理画面 + 左上汉堡设置栏 + 右上"卸载推理"徽标      │
│  mobile/client/settings.py   本地配置持久化（摄像头 / 阈值 / 推理图片大小…）          │
└───────────────────────────────────────────────────────────────────────────────────┘
```

对既有代码的改动**只有两处向后兼容的增量**（默认行为完全不变）：

1. `core/video_thread.py`：新增可选参数 `inference_size`（默认 `320`，与原硬编码值一致）
   与运行时接口 `set_inference_size()`，用于支持"推理图片大小设置"；
2. 新增 `mobile/` 目录与 `tests/test_mobile_*.py`，不改动 `main.py`、`ui_main.py`、
   `cloud_backend/` 等既有入口与后端。

---

## 2. 快速开始（桌面预览）

```powershell
# 1. 安装移动端界面依赖（Qt6，与桌面端 PyQt5 互不影响）
python -m pip install -r mobile/requirements-mobile.txt

# 2. 启动：会自动拉起本地推理服务（未运行时），随后显示手机形态界面
python -m mobile.app
# 或双击
mobile\run_mobile.bat
```

常用参数：

```powershell
python -m mobile.app --no-backend                  # 推理服务已在运行，只启动界面
python -m mobile.app --host 192.168.1.20 --port 8765   # 连接车机 / PC 上的推理服务
python -m mobile.app --fullscreen                  # 全屏（Android 上默认全屏）
```

单独启动推理服务（车机 / PC 侧）：

```powershell
python -m mobile.backend.frame_server --host 0.0.0.0 --port 8765 --source 0 --inference-size 320
# --source 也接受视频文件路径，便于无摄像头时演示：
python -m mobile.backend.frame_server --source D:\demo\road.mp4 --port 8765
```

> 手机连接时请填写车机 / PC 的局域网 IP，并在系统防火墙中放行该端口（默认 `8765`）。

---

## 3. 界面说明

* **画面区**：满屏显示 **AI 推理画面**（YOLO 检测框 / 跟踪 ID / TTC / 风险配色），等比缩放居中。
  不再显示预处理画面，也不再显示帧率。可在设置栏中开启右下角的 **BEV 俯视图画中画**。
* **左上角汉堡按钮**：展开滑入式设置栏（含遮罩，点击遮罩或 `✕` 收起，`Esc` 亦可）。
* **右上角徽标**：`卸载推理` + 状态
  | 状态 | 含义 |
  |---|---|
  | 运行中（绿） | 已连上推理服务且画面正常刷新 |
  | 连接中（橙） | 正在建立连接 / 等待首帧 |
  | 画面停滞（橙） | TCP 仍连着，但超过 3 秒没有新画面 |
  | 已断开（红） | 未连接或连接中断（自动重连） |

### 设置栏功能

| 分组 | 功能 | 服务端行为 |
|---|---|---|
| 切换摄像头 | 选择序号 0/1/2/3（手机端 0=后置主摄，1=前置） | 重建 `VideoThread` 并重新打开视频源 |
| 阈值设置 | 低置信度阈值（0.10–0.95）、边缘强度阈值（1.0–255.0） | 调用既有 `set_preprocess_thresholds()` |
| 推理图片大小 | 320 / 416 / 512 / 640（YOLO `imgsz`） | 调用新增的 `set_inference_size()`，下一帧生效 |
| 显示 | 叠加 BEV 俯视图画中画 | 服务端按需推送 BEV 画面 |
| 推理服务 | 主机 / 端口 + 重新连接 | 切换服务地址并重连 |
| 关于 | Qt / Python 版本与位数、恢复默认值 | — |

> **固定输入模型说明**：Ultralytics 导出的 `*_int8_openvino_model` 是**固定输入尺寸**模型
> （本仓库为 320）。此时移动端只会放开模型原生尺寸，其它尺寸会被服务端拒绝并给出原因
> （不会打断正在运行的推理）；如需自由调整 `imgsz`，请改用 FP32 权重
> `--model assets/weights/yolo11n.pt`（未导出 INT8 目录时 `imgsz` 可动态调整）。

设置项保存在 `mobile/mobile_settings.json`（已在 `.gitignore` 中忽略），
可通过环境变量 `FASTGUARD_MOBILE_SETTINGS` 指向其它配置文件。

---

## 4. 通信协议（`mobile/protocol.py`）

大端分帧：`MAGIC(4) | header_len(4) | header(JSON) | payload_len(4) | payload`。

| 方向 | 类型 | 说明 |
|---|---|---|
| 服务端 → 客户端 | `frame` | payload 为推理画面 JPEG，header 内嵌精简状态快照 |
| 服务端 → 客户端 | `bev` | payload 为 BEV 画面 JPEG（仅客户端开启时） |
| 服务端 → 客户端 | `status` | 引擎状态（`state` / `source` / `inference_size` / `error` 等，**不含帧率**） |
| 服务端 → 客户端 | `ack` / `error` | 指令执行结果 / 错误 |
| 客户端 → 服务端 | `cmd` | `set_source`、`set_thresholds`、`set_inference_size`、`set_bev`、`ping` |

状态快照示例：

```json
{
  "type": "status", "engine": "VideoThread", "state": "running", "running": true,
  "source": 0, "inference_size": 320, "weak_conf": 0.38, "edge_strength": 28.0,
  "bev": false, "model": "yolo11n_int8_openvino_model",
  "perspective": "前向视角", "risk": "安全", "ttc": null, "tracked": 2,
  "latency_ms": 42.7, "frame_count": 512, "last_frame_age": 0.03, "error": null
}
```

按设计要求，状态中**不包含帧率**字段，界面也不显示帧率。

---

## 5. Android 64 位打包

### 5.1 关键事实（先看这里）

| 事实 | 影响 |
|---|---|
| ``pyside6-android-deploy`` **只能在 Linux / macOS 上运行** | Windows 开发机不能直接出包（官方明确限制，见 Qt 文档 "only works with a Unix host"） |
| Android 版 PySide6 wheel **不在 PyPI 上**，只在 Qt 官方下载站 | ``pip download --platform android`` 会失败，必须从 ``download.qt.io`` 取 |
| Qt6 只提供 64 位 ABI | 仅支持 ``arm64-v8a``（真机）与 ``x86_64``（64 位模拟器），32 位一律拒绝 |
| 需要 NDK **r28c**（``28.2.13676358``） | 它是首个默认 16 KB 页对齐的 NDK，Android 15+ 设备必需 |
| 需要 JDK 17+ | buildozer / Gradle 的要求 |

因此有 **三条可用路径**：

| 路径 | 适用场景 |
|---|---|
| **A. GitHub Actions**（推荐） | 不用装任何东西：在仓库 Actions 里手动触发 ``Build Android APK (64-bit)``，产物在 Artifacts 中下载 |
| **B. WSL2 / Linux 主机** | 本机出包，执行 ``mobile/build_android_apk.sh`` |
| **C. Windows 上校验配置** | ``python -m mobile.packaging.android_deploy --check`` 可验证 staging / wheel / spec 是否正确，只是不执行最终构建 |

### 5.2 路径 A：GitHub Actions（推荐）

1. 打开仓库 → **Actions** → 左侧 ``Build Android APK (64-bit)``；
2. 点击 **Run workflow**，选择：
   * ``arch``：``aarch64``（真机，默认）或 ``x86_64``（64 位模拟器）；
   * ``mode``：``debug``（产出可直接安装的 ``.apk``）或 ``release``（产出上架用 ``.aab``）；
   * ``pyside_version``：默认 ``6.12.0``（与本地开发环境一致）。
3. 运行结束后在 **Artifacts** 里下载 ``fastguard-android-<arch>-<mode>``。

工作流会自动完成：安装 64 位 Python 3.10 + JDK 17 + buildozer → 安装 PySide6 →
用 Qt 官方脚本下载 NDK r28c / SDK → 解析 64 位 Android wheel → 校验配置 → 构建 → 上传产物。

> 首次构建需编译 Qt for Python，通常 30～60 分钟；工作流超时上限设为 240 分钟。
> 打 ``v*`` 标签也会自动触发同样的构建。

### 5.3 路径 B：WSL2 / Linux 主机

```bash
# 依赖：64 位 Python 3.10+、JDK 17+、git、buildozer 工具链
./mobile/build_android_apk.sh --arch aarch64 --mode debug     # 生成 .apk
./mobile/build_android_apk.sh --arch x86_64  --mode release   # 生成 .aab
./mobile/build_android_apk.sh --check                         # 只校验配置
adb install -r build/android/dist/FastGuard.apk               # 安装到手机
```

脚本会自动：安装 PySide6（Unix 上同时提供 ``pyside6-android-deploy``）与
``buildozer==1.6.0 / cython==0.29.33`` → 首次运行时用 Qt 官方脚本下载 NDK/SDK →
调用 ``mobile.packaging.android_deploy`` 完成构建。

### 5.4 打包脚本做了什么

``python -m mobile.packaging.android_deploy`` 补齐了官方工具未自动化的部分：

1. **精简 staging**：只把运行时需要的 ``mobile`` 子集（``app.py`` / ``protocol.py`` /
   ``platform_info.py`` / ``client/`` / ``ui/``）拷到 ``build/android/project``，
   并生成入口 ``main.py``（官方要求入口必须叫 ``main.py``）。
   ``mobile/backend``（PyQt5 推理服务端）与 ``packaging`` **不会**进入 APK，
   仓库里的 ``venv/``、``dist/``、演示文稿也不会被打包。
2. **解析 64 位 Android wheel**：读取 Qt 官方目录列表，挑选与宿主 PySide6 **版本一致**的
   ``android_aarch64`` / ``android_x86_64`` wheel，缓存到 ``build/android/wheels``
   （PySide6 约 86 MB、shiboken6 约 0.3 MB）；找不到同版本时回退到站点上的最高版本并提示。
3. **生成 ``pysidedeploy.spec``**：键集合与 PySide6 自带 ``default.spec`` 对齐，
   并写入 ``[android] wheel_pyside / wheel_shiboken``、``[buildozer] arch / mode`` 等。
4. **只允许 64 位**：``armeabi-v7a`` / ``x86`` 等 32 位 ABI 与 wheel 在解析与 spec 校验两处被拒绝。

常用命令：

```powershell
python -m mobile.packaging.android_deploy --list                 # 查看官方站点上的 64 位 wheel
python -m mobile.packaging.android_deploy --check                # 校验配置（任何平台可用）
python -m mobile.packaging.android_deploy --print-only           # 只打印将执行的官方命令
python -m mobile.packaging.android_deploy --arch x86_64 --mode release --clean
```

产物与构建目录（``build/`` 已在 ``.gitignore`` 中忽略）：

```
build/android/
├── project/            # staging 工程（含 main.py 与生成的 pysidedeploy.spec）
├── wheels/             # 下载的 64 位 Android wheel 缓存
└── dist/               # APK / AAB 输出目录
```

### 5.5 环境要求一览

| 项目 | 要求 |
|---|---|
| 构建主机 | Linux 或 macOS（官方限制）；Windows 用 GitHub Actions / WSL2 |
| Python | 64 位 3.10+（32 位会被脚本直接拒绝） |
| PySide6 | 与 Android wheel 版本一致（推荐 ``6.12.0``） |
| Android NDK | r28c（``28.2.13676358``） |
| Android SDK | ``platform-tools``、``platforms;android-35``、``build-tools;35.0.0`` |
| JDK | 17+ |

> 手机端无法派生 Python 子进程，因此 APK 只包含界面与协议客户端；
> 推理服务需在车机 / PC 上运行，手机通过局域网连接（设置栏"推理服务"中填写地址）。

---

## 6. 测试

```powershell
# 界面 / 协议 / 配置（离屏运行，无需显示器）
python -m pytest tests/test_mobile_ui.py -v

# Android 打包链路（64 位判定 / staging / spec / wheel 缓存）
python -m pytest tests/test_mobile_packaging.py -v

# 推理服务端到端（子进程 + 真实 JPEG 画面，耗时较长，默认跳过）
$env:FASTGUARD_MOBILE_E2E=1
python -m pytest tests/test_mobile_backend.py -v

# 校验 Qt 官方下载站上确实存在与宿主版本一致的 64 位 Android wheel（需联网）
$env:FASTGUARD_ANDROID_NETWORK=1
python -m pytest tests/test_mobile_packaging.py -k real_qt_index -v
```

说明：

* `mobile.backend.*` / `core.video_thread` 使用 **PyQt5**，移动端界面使用 **PySide6**，
  同一进程加载两套 Qt 绑定会崩溃，因此端到端测试通过独立子进程 + TCP 协议验证；
* 在本机环境下还需要注意导入顺序：`ultralytics / torch` 必须先于 `PyQt5` 导入
  （与桌面端 `main.py` 的顺序一致），否则 `torch` 的 `c10.dll` 会初始化失败（`WinError 1114`）。
  新增模块已按此顺序编写。

---

## 7. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 双击 `run_mobile.bat` 出现 `No Python at '"C:\Users\<别人>\...python.exe'` | 仓库里的 `venv/` 是从别的机器拷来的，其 `Scripts\python.exe` 是死链。新版脚本会自动跳过并改用系统解释器；也可直接删除 `venv/` 后重建 |
| 徽标长时间停在"连接中 / 画面停滞" | 首次启动需要加载 Torch / YOLO（INT8 还要编译 OpenVINO 模型），请耐心等待；若长时间无画面，查看 `logs/mobile_backend.log` |
| 状态栏提示"视频源未就绪，请检查摄像头序号是否可用" | 摄像头序号不存在或被其它程序（会议软件 / OBS）占用；在设置栏切换序号，或关闭占用程序 |
| 选择的推理图片大小被弹回 | 当前使用 INT8 固定输入模型（默认 320），改用 FP32 权重即可自由调整 |
| 手机连不上 PC | 确认防火墙已放行端口、服务以 `--host 0.0.0.0` 启动、手机与 PC 在同一网段，并在设置栏填写 PC 的局域网 IP |
| 服务端日志出现 `WinError 1114 ... c10.dll` | 导入顺序问题：`PyQt5` 被先于 `torch` 导入；新增代码已按正确顺序导入，扩展时请保持该顺序 |
| 切换摄像头后画面中断数秒 | 切换会重建引擎并重新加载模型，属预期行为 |
| 依赖安装很慢 / 占了几百 MB | `requirements-mobile.txt` 只装 `PySide6-Essentials`；若你手动装过 `PySide6` 元包，它会额外拉入 Addons / WebEngine / Pdf（实测约多 650 MB），可 `pip uninstall PySide6 PySide6-Addons PySide6-WebEngine PySide6-Pdf` 后改装 Essentials |
| 打包时报"只能在 Unix 主机上运行" | 这是 Qt 官方限制；Windows 请走 GitHub Actions 或 WSL2，见 [第 5 节](#5-android-64-位打包) |
| 打包时提示缺少 64 位 Android wheel | 确认宿主 PySide6 版本与 ``--version`` 一致；脚本会从 Qt 官方站点自动下载，也可用 ``--list`` 查看可用版本 |
| 打包时提示 32 位 wheel 被拒绝 | 预期行为：本项目只支持 64 位（``arm64-v8a`` / ``x86_64``） |

---

## 8. 目录结构

```
mobile/
├── app.py                      # 移动端入口（Qt6 / PySide6）
├── protocol.py                 # 与服务端共用的消息协议
├── platform_info.py            # Python / Qt 版本与位数
├── requirements-mobile.txt     # 移动端依赖（PySide6）
├── run_mobile.bat              # 桌面预览一键启动
├── backend/                    # 推理侧适配层（PyQt5，随车机 / PC 运行）
│   ├── engine_bridge.py        #   包装既有 VideoThread（丢弃预处理画面）
│   ├── frame_hub.py            #   最新帧缓存 + 单次 JPEG 编码
│   ├── model_info.py           #   权重信息（是否固定输入模型）
│   └── frame_server.py         #   TCP 服务（画面推送 + 指令处理）
├── client/                     # 手机侧（PySide6）
│   ├── transport.py            #   接收线程 + 指令队列
│   ├── settings.py             #   本地配置持久化
│   └── backend_launcher.py     #   桌面端自动拉起本地推理服务
├── ui/                         # 界面
│   ├── main_window.py          #   主窗口（画面 + 顶栏 + 抽屉）
│   ├── overlay.py              #   汉堡按钮 + "卸载推理"徽标
│   ├── drawer.py               #   设置栏（摄像头 / 阈值 / 推理图片大小）
│   ├── video_view.py           #   推理画面显示区（含 BEV 画中画）
│   └── theme.py                #   移动端深色主题
├── build_android_apk.sh        # Linux / macOS 一键打包 64 位 APK
└── packaging/
    ├── android_deploy.py       # 打包入口：staging + wheel + spec + 调用官方工具
    └── android_kit/            # 打包支撑（仅标准库，已单元测试）
        ├── common.py           #   常量、64 位判定、Qt 下载站访问
        ├── staging.py          #   生成精简的 staging 工程
        ├── spec.py             #   生成/校验 pysidedeploy.spec
        └── wheels.py           #   解析并下载 64 位 Android wheel

.github/workflows/build-android-apk.yml   # Linux runner 上构建 APK 并上传产物
```

---

## 9. 打包相关文件

| 文件 | 作用 |
|---|---|
| [mobile/build_android_apk.sh](build_android_apk.sh) | WSL2 / Linux / macOS 一键打包（自动装依赖、下载 NDK/SDK、调用打包入口） |
| [.github/workflows/build-android-apk.yml](.github/workflows/build-android-apk.yml) | GitHub Actions：手动触发或打 ``v*`` 标签时构建，产物上传到 Artifacts |
| [mobile/packaging/android_deploy.py](packaging/android_deploy.py) | 打包入口（``--list`` / ``--check`` / ``--print-only`` / ``--arch`` / ``--mode``） |
| [mobile/packaging/android_kit/](packaging/android_kit) | 支撑模块：staging、spec、wheel 解析（可在任意平台单元测试） |
| [tests/test_mobile_packaging.py](../tests/test_mobile_packaging.py) | 打包链路回归测试（39 条，含 64 位判定、staging、spec 与 wheel 缓存校验） |
