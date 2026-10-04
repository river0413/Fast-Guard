
# FastGuard — 车辆碰撞预警系统

[![Python](https://img.shields.io/badge/Python-3.10-blue)](https://www.python.org/)
[![PyTorch](https://img.shields.io/badge/PyTorch-2.0-red)](https://pytorch.org/)
[![YOLO](https://img.shields.io/badge/YOLO-v11-darkgreen)](https://github.com/ultralytics/ultralytics)
[![License](https://img.shields.io/badge/License-AGPL--3.0-orange)](https://www.gnu.org/licenses/agpl-3.0.html)

基于计算机视觉与深度学习的 **智能多视角防碰撞预警系统**。实时分析摄像头视频数据，检测追踪行人、车辆等目标，计算碰撞风险并分级预警。

> **参赛编号**: 20260093 &emsp;|&emsp; **参赛学校**: 华东理工大学 &emsp;|&emsp; **获奖作品**

---

## 目录

- [项目背景](#项目背景)
- [功能特性](#功能特性)
- [系统架构](#系统架构)
- [核心算法](#核心算法)
- [界面展示](#界面展示)
- [快速开始](#快速开始)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [团队信息](#团队信息)
- [AI 工具使用说明](#ai-工具使用说明)
- [参考资料](#参考资料)
- [许可证](#许可证)

---

## 项目背景

因驾驶员视野盲区、反应不及时及复杂路况下的判断失误所导致的交通事故占比高达 **90%**，"开门杀"、侧向变道碰撞、前向追尾是主要隐患。传统碰撞预警系统依赖高成本雷达、功能单一（仅针对前向或后向），缺乏对侧向盲区和行人/非机动车的有效预警。

FastGuard 旨在构建一个 **轻量化、低成本、高度智能化** 的碰撞预警解决方案，适用于日常驾驶、营运车辆及交通安全教育等场景。

### 核心创新

| 创新点 | 描述 |
|--------|------|
| **自适应视角识别** | 首创基于画面两侧区域运动特征的视角自动识别机制，摄像头朝向自动判断并动态切换预警逻辑 |
| **双模态预警算法** | 前向：改进的TTC计算模型 + 宽度变化率 + 相对速度 + 驾驶员反应时间；侧向：IPM构建世界坐标系防撞壁垒 |
| **全场景轻量化** | 跳帧推理、降采样、GPU加速，普通消费级硬件即可流畅运行 |

---

## 功能特性

### 多视角实时监测
- 同时处理 **前向**（追尾预警）和 **侧向**（盲区/开门杀预警）视野的碰撞风险
- 摄像头朝向自动识别，无需手动配置

### 四路视频流可视化
- **原始画面** — 无修饰的物理世界输入
- **预处理画面** — CLAHE增强、Sobel边缘检测等底层处理结果
- **AI 推理画面** — YOLO检测框、ByteTrack追踪、TTC倒计时、风险等级标注
- **BEV 俯视图** — IPM变换后的鸟瞰视角，直观展示目标空间关系

### 智能分级预警
- 🟢 **安全** — TTC > 阈值，正常行驶
- 🟡 **注意 (Warning)** — TTC 接近临界，黄色提醒
- 🔴 **危险 (Danger)** — 碰撞即将发生，红色警报 + 蜂鸣

### 性能优化
- **跳帧推理**：单目画面分上下两块，上方块每 3 帧推理 1 次、下方块每 3 帧推理 2 次（平均每帧 1 次），非推理帧复用上次结果
- **图像降采样**：视角分析缩至 160×120，计算量降低 ~99%
- **批量绘制**：中文字符批量渲染，避免逐条操作
- **GPU 加速**：CUDA 推理，CPU-GPU 无阻塞异步架构

### 其他
- 云端账户系统登录/注册（通过 `data/cloud_auth.json` 配置的后端路径校验，离线时自动跳过登录）
- 本地运行日志存储（SQLite3）
- 完整系统日志（GUI 实时滚动 + 文件持久化）
- 参数可调节（置信度阈值、边缘强度等）

---

## 系统架构

```
┌─────────────────────────────────────────────────┐
│                   表示层 (GUI)                     │
│  main.py / ui_main.py                            │
│  启动画面 | 主窗口 | 三路视频 | 控制面板 | 统计卡    │
└──────────────────────┬──────────────────────────┘
                       │ Qt Signal/Slot
┌──────────────────────▼──────────────────────────┐
│               业务逻辑层 (Core)                    │
│  video_thread.py — VideoThread (核心处理引擎)      │
│  ├─ 视频流读取 (摄像头/文件)                       │
│  ├─ YOLO 推理调度                                │
│  ├─ ByteTrack 多目标跟踪                         │
│  ├─ 图像预处理                                   │
│  └─ 风险判定与可视化绘制                           │
└──────────────────────┬──────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────┐
│                 算法层 (Algorithm)                 │
│  calculator.py    — TTCCalculator (碰撞时间)      │
│  ipm.py           — IPM_Transformer (逆透视变换)  │
│  view_classifier.py — ViewClassifier (视角识别)   │
│  deep_learning/   — 自定义模型组件                 │
└─────────────────────────────────────────────────┘
```

---

## 核心算法

### 1. 碰撞时间 (TTC) 计算

基于目标宽度变化率估算 TTC = w / (dw/dt)：
- 每目标维护 10 帧宽度历史队列，EMA 平滑 (α=0.3)
- dw/dt > 0（目标靠近）时计算 TTC，否则返回安全值 99s
- 5 帧 TTC 历史队列平滑输出
- **背景流过滤**：检测 vx 与偏离中心方向是否一致，过滤路侧横移树木/建筑
- **SDT 安全距离**：(v_ego + v_close) × 1.2s + 2m，动态阈值

### 2. 视角自动识别 (ViewClassifier)

基于 "死区像素对比" 的一票否决制：
1. 降采样至 160×120，转灰度
2. 提取左右各 20% 宽度 ROI，计算帧间 MSE
3. 两侧 MSE < 25.0 → 侧面视角；否则 → 前向视角
4. **迟滞锁定**：确认侧向需连续 10 帧 (MSE < 10)，切回前向需连续 30 帧

### 3. 逆透视变换 (IPM)

针孔相机模型 + 刚体变换，像素坐标 ↔ 地面世界坐标：

1. (u, v) → 相机坐标系归一化方向向量
2. 应用俯仰角 pitch (X轴) / 偏航角 yaw (Y轴) 旋转矩阵
3. 射线与地平面 (y=0) 求交 → 地面坐标 (X, Y)，单位米
4. 支持反投影：地面坐标 → 像素坐标

应用：目标测距、BEV 包络线绘制、横向/纵向速度计算

### 4. YOLO + ByteTrack 集成

- **模型**：YOLO11n Nano，输入 640×640
- **类别**：person, car, truck, bus, motorcycle, bicycle
- **跟踪**：ByteTrack + 卡尔曼滤波保持遮挡时 ID 连续性
- **过滤策略**：
  - 检测线以上 (40% 高度) 目标过滤
  - 宽高比异常过滤 (h/w > 3 或 w/h > 4)
  - 低置信度边缘强度辅助过滤 (conf < 0.38 需 Sobel > 28.0)
  - NMS (IoU > 0.6 行人与两轮车去重)
  - 连续 5 帧确认才纳入风险评估

---

## 界面展示

| 页面 | 说明 |
|------|------|
| 启动加载页 | 盾牌图标 + 进度条，自动初始化模型与环境 |
| 登录/注册页 | 账号由云端后端校验，支持记住密码；云端不可连接时跳过登录直接进入 |
| 主界面 | 左侧导航栏 + 三路视频 + 右侧指标面板 + 控制面板 |
| 参数设置 | 低置信度阈值、边缘强度阈值，支持恢复默认 |
| 系统日志 | 黑色瀑布流实时滚动，15条内存缓冲，文件按时间戳归档 |

**设计风格**：暗黑工业风 + 高对比度色彩，绿色(安全)/橙红(预警)/蓝色(操作)，圆角微阴影，无冗余装饰。

> 演示视频：[优酷链接](https://v.youku.com/v_show/id_XNjUyMzI3NzUyMA==.html)

---

## 快速开始

### 环境要求

| 类型 | 要求 |
|------|------|
| 操作系统 | Windows 11/10 |
| Python | 3.7+ |
| GPU (可选) | NVIDIA CUDA 11.8+ |
| 摄像头 | USB 摄像头或内置摄像头 (实时模式) |

### 安装步骤

```bash
# 1. 克隆/解压项目
git clone <repo-url>
cd FastGuard

# 2. 安装依赖
pip install -r requirements.txt
```

### 运行

```bash
# 方式一：批处理文件
双击 run_fastguard.bat

# 方式二：命令行启动
python main.py
```

### CPU 推理性能测试（OBS 虚拟摄像头）

测试前在 OBS 中加载城市天际线 1POV 视频并启动 OBS Virtual Camera，并确认 `assets\weights\yolo11n.pt` 权重文件已存在（或用 `--weights` 指定权重）。该脚本复现 `main.py` 的 CPU 推理分支：普通比例画面采用上下分块增强与 YOLO `predict`，超宽 SBS 画面采用 YOLO + ByteTrack `track`。采集、图像预处理、模型推理耗时分开统计；测试不包括 GUI 绘制及其余碰撞分析逻辑。

```bash
# 默认使用摄像头索引 0、测试 60 秒；根据本机设备调整 --source
python scripts\benchmark_cpu.py --source 0

# 可选：指定权重、测试时长、输出目录、推理分辨率与线程数
python scripts\benchmark_cpu.py --source 1 --weights assets\weights\yolo11n.pt --duration 120 --imgsz 320 --threads 8 --output-dir benchmark_results

# 如需对比 GPU：--device 0（有 CUDA 时）
python scripts\benchmark_cpu.py --source 1 --device 0
```

脚本按主程序的 2.4:1 宽高比阈值自动选择单目/双目分支；`--imgsz` 控制 YOLO 推理分辨率（默认 640，CPU 下 320 可提速约 1.6×），`--threads` 控制 torch CPU 线程数（默认物理核心数）。测试结果会写入 `benchmark_results`，包含逐帧 CSV、运行环境和统计摘要 JSON，以及覆盖全程的 FPS / 延迟 / 进程内存 PNG 图。CSV 的 `rolling_fps` 是 1 秒滑动帧率，`rss_mb` 为进程常驻内存；摘要提供平均处理帧率、模型调用吞吐量，以及预处理/帧周期/推理延迟的均值、中位数和 P95，另含内存起止值与漂移量（`process_memory_mb`）。长时运行（如 `--duration 900`）可用于观察热节流导致的速度衰减与内存泄漏。请在目标 i7-11800H 机器上运行，并以摘要中的 CPU 字段确认测试硬件。

> 实测（i7-11800H，OBS 640×480，60 秒）：CPU `imgsz=640` 约 14.0 FPS，CPU `imgsz=320` 约 21.8 FPS，GPU 约 29.9 FPS（触顶视频源 30 FPS 上限）。生产代码 `main.py`、`core/video_thread.py` 已采用 `imgsz=320` 并固定物理核心线程数。

### INT8 量化加速

本项目支持 OpenVINO INT8 量化推理。INT8 模型通过 `ultralytics` 导出（`model.export(format="openvino", int8=True, data=..., imgsz=320)`，校准数据来自 OBS 实时采集的 200 帧），产物为 `assets\weights\yolo11n_int8_openvino_model\`（约 3.2 MB）。

`main.py`、`core/video_thread.py` 在加载模型时会**优先加载 INT8 模型**（存在 `yolo11n_int8_openvino_model` 目录即启用），加载失败或目录缺失时自动回退 FP32 `.pt`，无需改动其他代码。

> 实测（i7-11800H，OBS 640×480，45 秒，`imgsz=320`）：FP32 约 21.8 FPS，INT8 OpenVINO 约 29.9 FPS（+37%，触顶视频源 30 FPS 上限），推理延迟 44.8 → 19.4 ms。INT8 的收益主要来自持续负载下功耗更低、热节流更轻。

依赖：运行 INT8 需 `openvino`（已加入 `requirements.txt`）；打包时 `build_windows.bat` 会 `--collect-all openvino`。校准数据集 `assets\calibration\` 仅用于导出，已加入 `.gitignore` 且不打包。

#### INT8 量化精度验证

使用标注数据集（COCO128，128 张标注图）对比 FP32 与 INT8 的精度/速度：

```bash
# 默认 fp32 + int8，imgsz 320 与 640（需先准备 coco128 数据集）
python scripts\validate_quantization.py --data coco128.yaml --imgsz 320,640

# 多尺寸扫描：每个尺寸一个固定输入的 INT8 模型（LABEL=PATH，标签以 int8 开头即归入量化曲线）
python scripts\validate_quantization.py --data coco128.yaml --imgsz 160,256,320,416,512,640 ^
  --models "fp32=assets\weights\yolo11n.pt,int8_320=assets\weights\yolo11n_int8_openvino_model"
```

> **导出模型输入尺寸固定**：OpenVINO 模型在导出时即固定输入尺寸（`yolo11n_int8_openvino_model` 为 320×320），脚本会自动跳过尺寸不匹配的组合并提示重新导出；多尺寸对比需为每个尺寸单独导出（`model.export(format="openvino", int8=True, data=..., imgsz=N)`）。

**精度扫描**（i7-11800H，COCO128，6 个尺寸 × 2 种精度）：

| imgsz | FP32 mAP50-95 | INT8 mAP50-95 | 精度变化 | FP32 单帧推理 | INT8 单帧推理 | 加速比 |
|------:|--------------:|--------------:|--------:|-------------:|-------------:|------:|
| 160 | 0.186 | 0.189 | **+1.4%** | 5.9 ms | 6.9 ms | 0.85× |
| 256 | 0.319 | 0.322 | **+1.1%** | 10.4 ms | 8.8 ms | 1.18× |
| 320 | 0.380 | 0.367 | −3.4% | 16.2 ms | 11.6 ms | 1.39× |
| 416 | 0.423 | 0.417 | −1.4% | 27.3 ms | 20.8 ms | 1.31× |
| 512 | 0.464 | 0.447 | −3.7% | 48.2 ms | 23.9 ms | 2.02× |
| 640 | 0.501 | 0.461 | −7.9% | 69.2 ms | 32.2 ms | 2.15× |

关键结论：

- **低分辨率下 INT8 精度反而略优**（160/256 尺寸为正增益）——量化在小模型上起到正则化作用。
- **精度损失随分辨率增大**（640 时 −7.9%），**但速度增益同步增大**（0.85× → 2.15×）：小尺寸受固定开销支配，大尺寸才体现 INT8 的计算优势。
- **召回率基本无损**：`imgsz=320` 时 FP32 与 INT8 的整体召回率均为 0.486；FastGuard 关注的安全类别（行人 +0.4%、卡车 +8.3%，其余持平）无一漏检恶化。

**端到端吞吐**（OBS 640×480 视频源，45 秒/组，含预处理与跳帧节奏）：

| 配置 | 平均 FPS | 单帧推理 | 帧延迟 P95 | 进程内存 |
|------|--------:|--------:|----------:|--------:|
| FP32 `imgsz=320` | 21.8 | 44.8 ms | 111.5 ms | 562 MB |
| FP32 `imgsz=512` | 15.0 | 76.3 ms | 159.9 ms | 578 MB |
| FP32 `imgsz=640` | 14.0 | 84.8 ms | 164.2 ms | 587 MB |
| **INT8 `imgsz=320`** | **29.9（触顶）** | 19.4 ms | 77.6 ms | 833 MB |
| **INT8 `imgsz=512`** | **25.0** | 37.5 ms | 99.2 ms | 848 MB |
| INT8 `imgsz=640` | 19.0 | 55.7 ms | 130.6 ms | 859 MB |

**最优工作点**：`INT8 @ imgsz=512` 的精度（0.447）比 `FP32 @ imgsz=320`（0.380）**高 17.6%**，同时帧率（25.0 FPS）也**更高**（21.8 FPS）——即在精度和速度上同时优于 FP32 默认配置。若需极致帧率（触顶 30 FPS 视频源），仍应选 `INT8 @ imgsz=320`。

> 注：INT8 的进程内存比 FP32 高约 270 MB（OpenVINO 运行时开销），在内存受限设备上需权衡。

#### 长时稳定性（15 分钟连续运行）

`python scripts\benchmark_cpu.py --source 1 --weights assets\weights\yolo11n_int8_openvino_model --imgsz 320 --duration 900`（INT8@320，26724 帧）：

| 时段 | 平均 FPS | 进程 RSS |
|------|--------:|--------:|
| 0–3 min | 30.12 | 829.7 MB |
| 3–6 min | 30.14 | 831.3 MB |
| 6–9 min | 30.04 | 832.4 MB |
| 9–12 min | 29.89 | 833.2 MB |
| 12–15 min | 29.94 | 834.0 MB |

- **无热节流**：首分钟 30.18 FPS → 末分钟 29.71 FPS（−1.6%），全程稳定在视频源 30 FPS 上限，说明笔记本长时间推理不会因发热降频。
- **内存收敛而非泄漏**：总漂移 +25.3 MB，但增速递减——前 7.5 分钟 0.46 MB/min，后 7.5 分钟 0.26 MB/min；各 3 分钟窗口增量依次为 +1.6 / +1.1 / +0.8 MB，末 3 分钟波动仅 0.8 MB。这是分配器预热与缓存增长趋于稳定的特征，**未见线性泄漏**。
- 测量口径：benchmark 会流式写入 CSV，并对绘图序列做有界降采样（`PLOT_MAX_POINTS`），因此长时运行不会被测试程序自身的内存占用污染。

### 前向链路功能回归测试

`tests\test_front_path.py` 覆盖前向（正面）链路：TTC 计算、正面碰撞检测器、正面报警去抖动、IPM 前向投影，以及「接近目标 → 报警升级」的端到端集成。**侧向/盲区检测模块不在测试范围内**。

```bash
pytest tests\test_front_path.py -v      # 需 pytest
python tests\test_front_path.py         # 无需 pytest，也可独立运行
```

23 项断言通过，覆盖：静止目标强制安全、接近目标触发告警、安全距离内强制危险、走廊外快速横移抑制、轨迹过期清理、去抖动确认帧与质量感知、报警升级时序，以及 IPM 前向测距与 SDT 单位。

> **已修复的三个问题**（均在 `core/ipm.py`、`core/front_detector.py`、`core/calculator.py`）：
>
> 1. **IPM 纵向轴符号**：`pixel_to_ground` 原本把地面映射到画面上半部（地平线在 v≈285 而非 v≈195），真实检测框底部（v≈300–480）一律返回 `None`。已改为上正（`y_cam = (cy - v) / fy`），`ground_to_pixel` 同步改为 `v = cy - fy * y_cam`。修复后地平线回到中心上方，距离随 v 增大单调递减（v=240→9.96 m，v=479→1.41 m），往返一致；侧向 `get_wall_pixel_x` 输出的 x 完全不变（492/524、169/145），此前恒为 `None` 的侧向 `pixel_to_ground` 也恢复为合理值。
> 2. **静止判定被覆盖**：`phys_distance < 3 m` 的近距硬触发排在静止判定之后并覆盖它，导致约 1.8 m 处的静止目标持续报危险。已加入 `and not is_static`。
> 3. **SDT 单位混用**：`sdt_dyn` 把 `vy`（像素/秒）与 `v_self_mps`（米/秒）相加，使 SDT 膨胀到数百米，`close_enough` 近乎恒真。已改为统一米制：`front_detector` 使用 IPM 距离差分得到的目标接近速度（m/s），`calculator` 因无米制目标速度而只取本车速度。
>
> **影响评估（更正）**：最初用 `v_self_mps=0` 合成场景测得「4/5 场景告警升级」，但在**生产等效参数**（`v_self_mps=11.1`、`distance=obj_dist` 由单目框高估距提供）下复测，告警等级在修复前后**均为危险（2 级）**——因为 SDT 早已饱和、`close_enough` 恒真。因此本次修复对生产告警等级的**净影响很小**，实际变化是：
> - `phys_distance` 的来源由**单目框高估距**切换为**IPM 地面距离**（前者在 `ground_distance` 为 `None` 时作为兜底，现已让位）；
> - 模型B（IPM 距离差分）TTC 由失效恢复为参与「双模型取最小值」。
>
> 修复 2、3 会**降低**误报（静止物体不再报危险；远处目标不再因 SDT 膨胀误判危险），同时保留真实近距危险告警（D<3 m 且非静止 → 危险）。
>
> **仍存在的相关单位问题（未修改）**：`front_detector` 中距离兜底 TTC `ttc_by_dist = abs(provided_distance / vy_world)` 与 `calculator` 中的 `v_rel_eff` 同样混用米制距离与像素/秒速度；`vy_gate`（用于横穿目标的 TTC 衰减）与 SDT 的 `-vy` 项作用符号相反。这些不在本次修复范围内。

> 注：COCO128 为小规模子集，逐类数值存在噪声；如需更严谨结论，请用完整 COCO val2017 或自有标注集复测。

### 打包为 Windows 可执行程序

项目使用 Python，以下脚本通过 PyInstaller 打包为可分发的 Windows 程序（并非把源码转换成 C）：

```bash
# 首次打包：先创建只含 CPU 版 PyTorch 的打包环境
setup_build_env.bat
build_windows.bat
```

产物为 `dist\FastGuard\FastGuard.exe`，需连同整个 `dist\FastGuard` 目录一起分发。

> **打包环境需安装 `openvino`**：`pip install -r requirements.txt` 会一并安装。若打包环境缺少 `openvino`，应用仍可运行但会在加载 INT8 模型失败后静默回退 FP32 `.pt`。

#### 产物瘦身

`build_windows.bat` 已内置瘦身措施，实测产物由约 5.6 GB 降到约 0.67 GB（启用 INT8/OpenVINO 后约 **0.92 GB**）：

| 措施 | 体积影响 | 原因 |
|------|----------|------|
| 用 `setup_build_env.bat` 安装 CPU 版 PyTorch 后再打包 | 约 -3.5 GB | 程序固定使用 `device = 'cpu'` 推理（见 `main.py`、`core/video_thread.py`），`torch/lib` 内的 CUDA 运行库不会被加载 |
| 脚本中的 `--exclude-module` 排除未被引用的包 | 约 -1.4 GB | PaddlePaddle（约 1.2 GB）、Polars/PyArrow、pandas、transformers、torchaudio 等由 `--collect-all ultralytics` 顺带收集，但在本程序的推理路径上不可达（已用 CPU 版 YOLO + ByteTrack 实测验证） |
| `--collect-all openvino` 引入 OpenVINO 运行时 | 约 +245 MB | 启用 INT8 量化推理所需；可在不需要 INT8 时移除该参数与 `assets\weights\yolo11n_int8_openvino_model\` |

打包验证（实测）：`dist\FastGuard` 共 915 MB，含 `FastGuard.exe`（27.5 MB）、`assets\weights\yolo11n_int8_openvino_model\`（3.2 MB）与 `openvino\`（243.5 MB，含 `_pyopenvino.cp310-win_amd64.pyd` 原生绑定及 `ultralytics\nn\backends\openvino.py`）。校准数据集 `assets\calibration\` 未进入产物。

其他注意事项：

- `dist/`、`build/`、`*.spec` 已在 `.gitignore` 中，不要把 `dist\FastGuard` 重新压缩后提交到仓库。
- 如需自行压缩分发，请压缩整个 `dist\FastGuard` 目录；其中大部分是已压缩的 DLL，Zip 通常只能再缩小约三成。
- 若确实需要 CUDA 推理，用带 CUDA 版 PyTorch 的环境打包即可：`set FASTGUARD_BUILD_PYTHON=D:\path\to\python.exe` 后再运行 `build_windows.bat`，产物会增大约 3.5 GB。
- `requirements.txt` 中的 `lap` 是 ByteTrack 匹配的必需依赖，打包后位于 `dist\FastGuard\lap\`。

### 使用流程

1. 登录系统（账号由云端账户系统校验；若云端不可连接，则跳过登录直接进入）
2. 点击「开启摄像头」实时监控，或「导入视频」离线分析
3. 观察三路视频画面与实时预警信息
4. 在「设置」中调整检测参数适配不同场景
5. 通过「系统日志」查看运行记录与预警历史

### 云端账户系统配置

登录与注册均请求云端后端，配置位于 `data/cloud_auth.json`（首次运行自动生成）：

```json
{
  "base_url": "https://your-cloud-host",
  "login_path": "/api/fastguard/auth/login",
  "register_path": "/api/fastguard/auth/register",
  "timeout": 5
}
```

- 登录请求：`POST {base_url}{login_path}`，JSON 体 `{"username": "...", "password": "..."}`，期望返回 `{"success": true, "role": "admin|user"}`
- 注册请求：`POST {base_url}{register_path}`，JSON 体相同，期望返回 `{"success": true}`
- 也可通过环境变量 `FASTGUARD_CLOUD_AUTH_CONFIG` 指定其他配置文件路径
- `base_url` 可包含路径前缀（如 `https://host/backend`），会与 `login_path` / `register_path` 拼接
- `base_url` 为空、网络异常或请求超时视为“无法连接云端”，此时跳过登录，以管理员身份进入本地系统

---

## 项目结构

```
FastGuard/
├── main.py                   # 主程序入口
├── ui_main.py                # 主界面定义
├── run_fastguard.bat         # 批处理启动脚本
├── requirements.txt          # Python 依赖清单
├── calculator.py             # TTC 碰撞时间计算器
├── ipm.py                    # IPM 逆透视变换模块
├── view_classifier.py        # 视角自动分类器
├── video_thread.py           # 视频处理线程 (核心引擎)
├── front_collision_detector.py # 前向碰撞检测器
├── side_collision_detector.py # 侧向碰撞检测器
├── collision_alarm.py        # 蜂鸣报警模块
├── reasoning_logger.py       # 决策日志记录器
├── front_alarm.py            # 前向视觉预警
├── side_alarm.py             # 侧向视觉预警
├── side_ipm.py               # 侧向专用 IPM
├── auth/                     # 用户认证模块
│   ├── db.py                 # LogDB 本地日志存储
│   ├── cloud.py              # 云端账户系统客户端
│   ├── ui.py                 # 登录/注册对话框
│   └── admin.py              # 后台管理面板
├── cloud_backend/            # 云端账户后端 (Flask，独立部署)
│   ├── app.py                # 登录/注册/健康检查接口
│   ├── db.py                 # SQLite 用户存储 (Werkzeug 加盐哈希)
│   └── .env.example          # 端口与管理员账号配置模板
├── deep_learning/            # 深度学习组件
├── assets/                   # 静态资源
│   └── weights/              # 模型权重 (yolo11n.pt)
├── data/                     # 测试视频数据
│   ├── fastguard.db          # SQLite 本地日志数据库
│   └── cloud_auth.json       # 云端账户系统配置
├── logs/                     # 系统日志 (按时间戳归档)
└── bytetrack.yaml            # ByteTrack 跟踪器配置
```

---

## 技术栈

### 核心框架

| 技术 | 版本 | 用途 |
|------|------|------|
| [PyTorch](https://pytorch.org/) | 2.0.1 | 深度学习推理框架 |
| [Ultralytics YOLO](https://github.com/ultralytics/ultralytics) | 8.0.0+ | 目标检测与追踪 |
| [OpenCV](https://opencv.org/) | 4.8.0 | 视频处理、图像预处理 |
| [PyQt5](https://www.riverbankcomputing.com/software/pyqt) | 5.15.9 | 图形用户界面 |
| [NumPy](https://numpy.org/) | 1.24.3 | 数值与矩阵计算 |
| [Pillow](https://python-pillow.org/) | 9.5.0 | 中文字符渲染 |

### 算法组件

- **目标检测**：YOLO11n (Nano) 预训练 + 迁移学习
- **多目标跟踪**：ByteTrack + 卡尔曼滤波
- **坐标变换**：IPM 逆透视变换 (针孔相机模型)
- **风险评估**：TTC + SDT + 背景流过滤
- **视角识别**：死区像素对 MSE 比较 + 迟滞锁定

### 数据存储

- SQLite3 (本地运行日志)
- JSON (记住密码缓存、云端账户系统配置)
- YAML (跟踪器配置)
- 文本日志 (按时间戳归档)

---

## 团队信息

| 角色 | 姓名 | 院系 | 专业 | 年级 |
|------|------|------|------|------|
| 组长 (算法) | 王一帆 | 商学院 | 计算机与金融双学位 | 2024级 |
| 组员 (系统集成) | 姚家辉 | 信息科学与工程学院 | 信息工程 | 2024级 |
| 组员 (前端/测试) | 叶泽楷 | 信息科学与工程学院 | 信息工程 | 2024级 |

**指导教师**: 胡庆春 (信息科学与工程学院)

### 分工

- **王一帆**：YOLO 模型优化、视角自动识别算法 (ViewClassifier)、TTC 计算模块、算法框架搭建
- **姚家辉**：侧向碰撞检测器 (SideCollisionDetector)、IPM 集成、视频处理线程 (VideoThread)、双目视觉支持
- **叶泽楷**：PyQt5 界面设计、三路视频显示、进度控制、参数设置、多场景测试、技术文档撰写

### 开发周期

2026年1月底 — 2026年4月中旬，历时约 **10 周**。

---

## AI 工具使用说明

### 使用的大语言模型/工具

| 工具 | 用途 |
|------|------|
| **Trae IDE** | 核心 IDE，管理工程代码仓库与模块化重构 |
| **CodeBuddy** | 与 Trae 交替使用 |
| **DeepSeek (V2/Coder)** | 复杂空间渲染算法与前端逻辑推理 |
| **Kimi (长文本版)** | 超长文本解析与结构化数据提取 |
| **GLM-4** | UI 界面样式代码生成、申报文档润色 |

### AI 辅助的环节

- **立项**：梳理 ADAS 市场痛点，规划系统功能需求图谱（IPM 生成 BEV 的创意即由 AI 提出）
- **编程**：动态焦距校准算法、TTC 动态阈值、Sobel 边缘强度过滤算法、QSS 样式表生成
- **调试**：诊断 VideoThread 多线程竞态与内存错误，提供线程锁方案
- **文档**：GLM-4 辅助申报材料润色统筹

### 验证机制

- IPM 矩阵代码：开发模式下绘制虚拟网格，用已知宽度车辆验证 BEV 3D 数据距离
- 多目标追踪与视角切换：放入数小时含复杂光影的历史视频中运行，通过 system_log 排查误报与资源溢出

---

## 参考资料

1. 张新钰, 高洪波, 赵建辉, 等. 基于深度学习的自动驾驶技术综述[J]. 清华大学学报, 2018.
2. KILICARSLAN M, ZHENG J Y. Predict vehicle collision by TTC from motion using a single video camera[J]. IEEE TITS, 2019.
3. 赵浩帆, 宋文爱, 章永来, 等. 基于改进YOLOv8的车辆碰撞预警方法研究[J]. 现代电子技术, 2025.
4. 宫圣鑫, 孙鑫. 基于TTC与AS的邻车切入场景下车辆主动避撞行为决策研究[J]. 电子测量技术, 2024.
5. 乔维高, 徐学进. 无人驾驶汽车的发展现状及方向[J]. 上海汽车, 2007.
6. 杨智涵, 唐玉敏. 基于融合注意力机制的YOLOv5神经网络在自动驾驶识别中的应用研究[J]. 汽车维修与保养, 2026.
7. 李永思, 李帅景. 基于计算机视觉的自动驾驶环境感知算法优化[J]. 汽车电器, 2026.
8. 吴文欢, 陈杰, 王文舒. DPM-YOLO:面向自动驾驶复杂场景的多尺度自适应目标检测算法[J]. 电子测量与仪器学报, 2026.
9. 阳逍, 杨圆娇, 刘许. 融合图像识别与毫米波雷达的车辆前向碰撞预警系统[J]. 汽车与新动力, 2025.
10. 刘佳怡, 刘忠富. 汽车碰撞预警系统应用综述[J]. 山西电子技术, 2025.

---

## 许可证

本项目底层基于 [Ultralytics YOLOv11](https://github.com/ultralytics/ultralytics)，若涉及商业化需遵循其 **AGPL-3.0** 协议。

OpenCV ([Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0)) 与 PyTorch ([BSD](https://opensource.org/licenses/BSD-3-Clause)) 可免费使用。

---

<p align="center">
  <b>FastGuard</b> — 让每一次出行都更安全
</p>
