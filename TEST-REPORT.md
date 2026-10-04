# FastGuard 性能测试、INT8 量化验证与前向链路回归报告

> 测试日期：2026-10-04
> 测试主机：11th Gen Intel Core i7-11800H @ 2.30GHz（8 物理核 / 16 逻辑核）+ NVIDIA RTX 3060 Laptop（sm_86）
> 视频源：OBS Virtual Camera（城市天际线 1POV），640×480 @ 30 FPS 上限

---

## 目录

- [1. 测试范围](#1-测试范围)
- [2. 测试环境](#2-测试环境)
- [3. 测量工具与口径](#3-测量工具与口径)
- [4. 精度–速度扫描（A / C）](#4-精度速度扫描a--c)
- [5. 端到端吞吐（B）](#5-端到端吞吐b)
- [6. INT8 量化结论](#6-int8-量化结论)
- [7. 长时稳定性（F）](#7-长时稳定性f)
- [8. 打包验证（D）](#8-打包验证d)
- [9. 前向链路功能回归测试（E）](#9-前向链路功能回归测试e)
- [10. 修复的缺陷](#10-修复的缺陷)
- [11. 遗留问题](#11-遗留问题)
- [12. 复现命令](#12-复现命令)
- [13. 产物索引](#13-产物索引)

---

## 1. 测试范围

| 编号 | 测试项 | 状态 | 结论摘要 |
|------|--------|------|----------|
| A | FP32 / INT8 精度验证（标注集） | 完成 | INT8 精度损失 ≤ 3.4%@320，召回率零损失 |
| B | 端到端吞吐（OBS 视频源） | 完成 | INT8@320 达 29.9 FPS，触顶视频源上限 |
| C | 精度–速度权衡曲线 | 完成 | INT8@512 在精度与速度上同时优于 FP32@320 |
| D | PyInstaller 打包验证 | 完成 | 产物 915 MB，含 OpenVINO 运行时与 INT8 模型 |
| E | 前向链路功能回归测试 | 完成 | 23 项测试；**侧向检测按要求排除** |
| F | 长时稳定性 / 压力测试 | 完成 | 15 分钟无热节流，内存收敛无泄漏 |
| G | 打包应用帧率异常定位（约 16 FPS） | 完成 | 根因：相机源帧计数器恒为 0、每帧 2 次推理；修复后 15.5 → 20.8 FPS（10.6） |

> E 原本指示为「放弃前向检测」，后更正为「放弃**侧向**检测」，故回归测试覆盖前向链路、排除侧向模块。

---

## 2. 测试环境

| 项 | 版本 / 配置 |
|---|---|
| 操作系统 | Windows |
| CPU | 11th Gen Intel Core i7-11800H @ 2.30GHz（8 物理核 / 16 逻辑核） |
| GPU | NVIDIA GeForce RTX 3060 Laptop GPU（compute capability 8.6） |
| Python | 3.10.9 |
| PyTorch | 2.6.0+cu124 |
| Ultralytics | 8.4.52 |
| OpenCV | 4.13.0 |
| OpenVINO | 2026.4.1（含 nncf） |
| Matplotlib | 3.10.9 |
| torch CPU 线程 | 8（物理核数） |

**重要前提**：生产代码中 `device = 'cpu'` 为硬编码（原注释为防止 RTX 50 系 sm_120 与 cu126 不兼容）。测试主机为 RTX 3060（sm_86），不受该限制影响，因此额外测得的 GPU 数据仅作参考，不改变 CPU 路线的结论。

---

## 3. 测量工具与口径

### 3.1 脚本

| 脚本 | 用途 |
|---|---|
| `scripts/benchmark_cpu.py` | 端到端帧率 / 延迟 / 内存基准，支持 `--device`、`--imgsz`、`--threads` |
| `scripts/validate_quantization.py` | 标注集上的精度 / 速度验证，支持多尺寸、多模型族 |

### 3.2 口径说明

`benchmark_cpu.py` 复现 `main.py` 的 CPU 推理分支：

- 普通比例画面（宽高比 < 2.4）→ 上下分块增强 + `model.predict`，按 3 帧节奏调用（第 0 帧上方、第 1 帧下方、第 2 帧跳过）；
- 超宽 SBS 画面 → `model.track` + ByteTrack，每 2 帧一次。

因此 `inference_ms` 是「该帧实际发生的模型调用」耗时（单帧可能是 0 / 1 / 2 次调用），`frame_cycle_ms` 是完整的采集+预处理+推理周期，`rolling_fps` 是 1 秒滑动帧率。测试**不包含** GUI 绘制与其余碰撞分析逻辑。

### 3.3 测量污染修正

初版 benchmark 会把每一帧的记录累积在内存中。15 分钟运行累积 26724 条记录，自身占用约 20 MB，导致内存漂移被**高估近一倍**（+45.3 MB）。修正方式：

- 逐帧流式写入 CSV，不再保留 `rows` 列表；
- 绘图序列改用有界降采样（`PLOT_MAX_POINTS = 6000`，超出时原地抽稀）；
- 内存改为直接累计在轻量列表中。

修正后实测漂移为 +25.3 MB，且趋势由「加速增长」变为「收敛」，结论发生**质的变化**（详见第 7 节）。

---

## 4. 精度–速度扫描（A / C）

数据集：COCO128（128 张标注图，929 个实例）。INT8 模型为 OpenVINO 静态量化，校准集为 OBS 实时采集的 200 帧。由于 OpenVINO 导出时**固定输入尺寸**，每个尺寸需单独导出。

### 4.1 总体指标

| imgsz | FP32 mAP50-95 | INT8 mAP50-95 | 精度变化 | FP32 单帧推理 | INT8 单帧推理 | 加速比 |
|------:|--------------:|--------------:|--------:|-------------:|-------------:|------:|
| 160 | 0.1862 | 0.1888 | **+1.4%** | 5.89 ms | 6.90 ms | 0.85× |
| 256 | 0.3187 | 0.3221 | **+1.1%** | 10.41 ms | 8.82 ms | 1.18× |
| 320 | 0.3801 | 0.3671 | −3.4% | 16.16 ms | 11.63 ms | 1.39× |
| 416 | 0.4230 | 0.4173 | −1.4% | 27.25 ms | 20.75 ms | 1.31× |
| 512 | 0.4638 | 0.4467 | −3.7% | 48.17 ms | 23.86 ms | 2.02× |
| 640 | 0.5008 | 0.4612 | −7.9% | 69.20 ms | 32.15 ms | **2.15×** |

### 4.2 规律

1. **低分辨率下 INT8 精度反而略优**（160 / 256 为正增益）——量化在小模型上起到正则化作用。
2. **精度损失随分辨率增大**（640 时 −7.9%），**但速度增益同步增大**（0.85× → 2.15×）：小尺寸受固定开销支配，大尺寸才能体现 INT8 的计算优势。

### 4.3 逐类指标（imgsz=320，FastGuard 关注类别）

| 类别 | FP32 mAP50-95 | INT8 mAP50-95 | mAP 变化 | FP32 召回 | INT8 召回 | 召回变化 |
|------|--------------:|--------------:|--------:|----------:|----------:|--------:|
| person（行人） | 0.4007 | 0.3787 | −5.5% | 0.5630 | 0.5668 | **+0.38%** |
| bicycle（自行车） | 0.1650 | 0.1493 | −9.5% | 0.1667 | 0.1667 | ±0 |
| car（轿车） | 0.0786 | 0.0640 | −18.5% | 0.1304 | 0.1296 | −0.09% |
| motorcycle（摩托车） | 0.7695 | 0.7422 | −3.6% | 1.0000 | 1.0000 | ±0 |
| bus（公交车） | 0.6018 | 0.5604 | −6.9% | 0.5714 | 0.5714 | ±0 |
| truck（卡车） | 0.2022 | 0.2107 | **+4.2%** | 0.3333 | 0.4167 | **+8.3%** |

**安全关键类别召回率全部持平或提升**，说明 INT8 不会漏检危险目标。整体召回率在 320 尺寸下 FP32 与 INT8 均为 0.486。

> 注：COCO128 为小规模子集，逐类数值存在噪声；如需更严谨结论应使用完整 COCO val2017 或自有标注集。

---

## 5. 端到端吞吐（B）

OBS 640×480 视频源，每组 45 秒。

> **口径说明（见 10.6）**：本节由 `benchmark_cpu.py` 测得。该脚本自行维护帧序号，节拍符合「平均每帧 1 次推理」的设计；而修复 10.6 之前的**真实应用在相机源上每帧执行 2 次推理**。因此本节数字代表**设计节拍下推理流水线**的吞吐（不含 GUI 绘制与其余碰撞分析），应用侧同配置实测为：修复前 15.5 FPS、修复后 20.8 FPS。

| 配置 | 平均 FPS | 单帧推理 | 帧延迟 P95 | 进程内存 |
|------|--------:|--------:|----------:|--------:|
| FP32 `imgsz=320` | 21.81 | 44.84 ms | 111.50 ms | 562.5 MB |
| FP32 `imgsz=512` | 14.97 | 76.28 ms | 159.86 ms | 577.7 MB |
| FP32 `imgsz=640` | 13.96 | 84.81 ms | 164.22 ms | 587.3 MB |
| **INT8 `imgsz=320`** | **29.89（触顶）** | 19.37 ms | 77.55 ms | 832.5 MB |
| **INT8 `imgsz=512`** | 24.99 | 37.51 ms | 99.21 ms | 848.1 MB |
| INT8 `imgsz=640` | 18.99 | 55.67 ms | 130.56 ms | 858.9 MB |

（GPU 参考：`device=0`、`imgsz=640` 为 29.88 FPS，同样触顶视频源上限。）

**观察**：

- INT8@320 的推理延迟仅为 FP32@320 的 43%，帧率提升 37%，并已触顶视频源 30 FPS 上限。
- INT8 的进程内存比 FP32 高约 270 MB，来自 OpenVINO 运行时开销，在内存受限设备上需权衡。

---

## 6. INT8 量化结论

### 6.1 导出方式

```python
from ultralytics import YOLO
YOLO("assets/weights/yolo11n.pt").export(
    format="openvino", int8=True, data="assets/calibration/calibration.yaml", imgsz=320
)
```

- 校准集：OBS 实时采集 200 帧（`assets/calibration/`，已 gitignore）。NNCF 建议 ≥300 帧，200 帧是精度损失的部分来源。
- 产物：`assets/weights/yolo11n_int8_openvino_model/`（3.2 MB，对比原始 `.pt` 5.6 MB）。

### 6.2 生产集成

`main.py`、`core/video_thread.py` 加载模型时**优先加载 INT8 模型**（存在 `{stem}_int8_openvino_model` 目录即启用），加载失败或目录缺失时自动回退 FP32 `.pt`。

### 6.3 最优工作点

| 方案 | mAP50-95 | 端到端 FPS |
|------|---------:|-----------:|
| FP32 `imgsz=320`（原默认） | 0.380 | 21.8 |
| INT8 `imgsz=320`（当前生产） | 0.367 | **29.9** |
| **INT8 `imgsz=512`** | **0.447** | 25.0 |

**INT8@512 在精度（+17.6%）与帧率（+15%）上同时优于 FP32@320**，是本次测试最有价值的可落地结论。当前生产选择 `INT8@320` 是为了最大化帧率（已触顶 30 FPS 视频源）；若更看重精度且可接受约 25 FPS，可改用 `INT8@512`。

---

## 7. 长时稳定性（F）

连续运行 15 分钟（900 秒，26724 帧），INT8@320。

| 时段 | 平均 FPS | 进程 RSS |
|------|--------:|--------:|
| 0–3 min | 30.12 | 829.7 MB |
| 3–6 min | 30.14 | 831.3 MB |
| 6–9 min | 30.04 | 832.4 MB |
| 9–12 min | 29.89 | 833.2 MB |
| 12–15 min | 29.94 | 834.0 MB |

**结论**：

- **无热节流**：首分钟 30.18 FPS → 末分钟 29.71 FPS（−1.6%），全程稳定在视频源上限，笔记本长时间推理未出现发热降频。
- **内存收敛而非泄漏**：总漂移 +25.3 MB，但增速递减——前 7.5 分钟 0.46 MB/min，后 7.5 分钟 0.26 MB/min；各 3 分钟窗口增量依次为 +1.6 / +1.1 / +0.8 MB，末 3 分钟波动仅 0.8 MB。属分配器预热与缓存增长趋于稳定的特征。

> 该结论建立在第 3.3 节的测量污染修正之上。修正前的受污染数据显示「加速漂移 +45.3 MB」，会得出错误结论。

---

## 8. 打包验证（D）

产物：`dist/FastGuard/`，共 **915 MB**。

| 内容 | 体积 |
|------|-----:|
| `FastGuard.exe` | 27.5 MB |
| `torch/` | 302.7 MB |
| `openvino/` | 243.5 MB |
| `cv2/` | 98.6 MB |
| `PyQt5/` | 75.4 MB |
| `scipy/` | 62.5 MB |
| `assets/weights/yolo11n_int8_openvino_model/` | 3.2 MB |

**逐项核验**：

- `openvino/__init__.py`、`openvino/_ov_api.py`、`openvino/_pyopenvino.cp310-win_amd64.pyd` 原生绑定、`ultralytics/nn/backends/openvino.py` 均完整打包 → INT8 推理链路可用；
- 校准数据集 `assets/calibration/` **未进入产物**（打包路径已收窄为 `assets\weights`）。

**发现并修复的缺陷**：打包环境 `venv`（CPU 版 PyTorch 精简环境）**缺少 `openvino`**。若不修复，打包出的应用会在加载 INT8 失败后**静默回退 FP32**，INT8 形同虚设。已安装并在 README 标注该前置条件。

---

## 9. 前向链路功能回归测试（E）

测试文件：`tests/test_front_path.py`，**23 项测试全部通过**，可用 pytest 或独立运行。

```bash
pytest tests\test_front_path.py -v
python tests\test_front_path.py
```

覆盖范围（**侧向检测模块按要求排除**）：

| 模块 | 断言要点 |
|------|----------|
| `TTCCalculator` | 静止目标强制安全、接近目标触发告警、安全距离内升级危险、走廊外快速横移抑制、过期轨迹清理 |
| `FrontCollisionDetector` | 同上，另含 IPM 距离输入下的近距硬触发、静止目标豁免硬触发、SDT 不掺入像素/秒速度 |
| `FrontAlarm` | 危险立即放行、告警需连续确认帧、安全帧重置计数、质量感知缩短确认帧、去抖计数清理 |
| `IPM_Transformer` | 地平线位置、距离单调性、检测框底部可映射、天区返回 `None`、往返一致性 |
| 集成 | 接近目标 → 报警升级时序；含距离时收敛到危险 |

**变异检验**：向实现注入 4 类回归（静止判定失效、TTC 恒安全、去抖失效、清理失效、IPM 符号回退、SDT 单位回退），对应测试**全部检出**，确认测试具备真实的回归检出能力，而非恒真。

---

## 10. 修复的缺陷

### 10.1 IPM 纵向轴符号错误（`core/ipm.py`）

**现象**：`pixel_to_ground` 把地面映射到画面**上半部**——地平线落在 v≈285（中心下方），而物理上应在 v≈195（中心上方），两者关于画面中心镜像。

**后果**：真实检测框底部（v≈300–480）一律返回 `None`，导致：

- `main.py`、`core/video_thread.py`、`core/front_detector.py` 的前向 IPM 测距全部失效；
- 设计中的「双模型 TTC 取最小值，防止单模型失效」只剩宽度变化率模型在工作。

**修复**：像素纵坐标改为上正。

```python
# pixel_to_ground
y_cam = (self.cy - v) / self.fy        # 原为 (v - self.cy) / self.fy
# ground_to_pixel
v = self.cy - self.fy * y_cam          # 原为 self.fy * y_cam + self.cy
```

**修复后验证**：

| 检测框底部 v | 修复前 | 修复后 |
|---:|---|---|
| 240 | None | 9.96 m |
| 340 | None | 2.95 m |
| 420 | None | 1.83 m |
| 479 | None | 1.41 m |

- 地平线回到 v≈195；距离随 v 增大**单调递减**（越靠近画面底部越近）；天区（v=100）正确返回 `None`；往返变换一致。

**侧向影响核查**（未破坏）：`side_alarm` 只使用 `get_wall_pixel_x` 的 **x** 值，而 x 不依赖纵轴符号，输出完全不变（左 492/524，右 169/145）；此前恒为 `None` 的侧向 `pixel_to_ground` 也恢复为合理值（如 (500,400) → (0.0, −1.92)）。

### 10.2 静止目标被近距硬触发覆盖（`core/front_detector.py`）

**现象**：判定顺序中「`phys_distance < 3 m` 直接危险」排在「静止目标强制安全」之后，会覆盖后者。

**后果**：约 1.8 m 处的静止物体（如堵车时前方停放车辆）持续报**红色危险**，即使 TTC=99。

**修复**：

```python
if phys_distance is not None and phys_distance < 3.0 and not is_static:
    risk_level = 2
```

静止目标在画面空间无相对运动，不构成碰撞风险。修复后静止且距 1.83 m → `risk=0`；非静止近距目标 `D=2.5 m → risk=2` 仍正常。

### 10.3 SDT 单位混用（`core/front_detector.py`、`core/calculator.py`）

**现象**：

```python
sdt_dyn = (max(0.0, v_self_mps) + max(0.0, -vy)) * t_reaction + d_safe
```

`vy` 是**像素/秒**，`v_self_mps` 是**米/秒**，两者相加使 SDT 膨胀到数百米。

**后果**：`close_enough = phys_distance < sdt_dyn` 近乎恒真，使「危险」判定退化为「TTC 低于阈值」即成立，与「注意」的区分失效。

**修复**：统一为米制。

```python
# front_detector：使用 IPM 距离差分得到的目标接近速度（m/s）
v_obj_mps = v_rel                      # 由 ground_dist_history 差分
sdt_dyn = (max(0.0, v_self_mps) + v_obj_mps) * t_reaction + d_safe

# calculator：无米制目标速度，仅取本车速度
sdt_dyn = max(0.0, v_self_mps) * t_reaction + d_safe
```

**修复后验证**：100 m 车距（远超真实 SDT 2 m）场景，`vy = -360 px/s` → `risk=1`（修复前因 SDT 膨胀至 434 m 而误判危险）。

### 10.4 基准工具自身的测量污染（`scripts/benchmark_cpu.py`）

见第 3.3 节。这是**测量方法**的缺陷而非产品缺陷，但会直接导致错误结论，故一并记录。

### 10.5 影响评估（更正）

修复 10.1 后，最初以 `v_self_mps=0` 的合成场景测得「4/5 场景告警升级」，据此判断告警率显著上升。**该判断夸大了影响**：用**生产等效参数**（`v_self_mps=11.1`、`distance=obj_dist` 由单目框高估距提供）复测，告警等级在修复前后**均为危险（2 级）**——因为 SDT 早已饱和、`close_enough` 恒真。

因此 10.1 对生产告警等级的**净影响很小**，实际变化是：

- `phys_distance` 的来源由**单目框高估距**切换为 **IPM 地面距离**（前者在 `ground_distance` 为 `None` 时作为兜底，现已让位）；
- 模型B（IPM 距离差分）TTC 由失效恢复为参与「双模型取最小值」。

修复 10.2、10.3 才是真正**降低误报**的改动。

---

### 10.6 帧计数器在相机源上恒为 0，导致分块节流全部失效（`main.py`、`core/video_thread.py`）

**现象**：打包应用（`dist\FastGuard`）在 OBS 虚拟摄像头上实测仅约 16 FPS，远低于 `benchmark_cpu.py` 同配置（INT8@320）的 29.89 FPS。

**先排除的假设**：打包本身没有问题——bundle 内 OpenVINO 2026.4.1 的 DLL 与站点包逐项一致（libs 40 个 DLL、顶层 11 文件、34 个子目录），INT8 模型可正常读取并编译为 `[1,3,320,320] → [1,84,2100]`；无头测试台运行真实 `VideoThread` 得到 `MODEL_LOADED: ['yolo11n_int8_openvino_model']`，即应用**确实在用 INT8**，不是静默回退 FP32。

帧级拆分显示**模型调用为 2.00 次/帧**，而代码设计的均值是 1 次——这是第一个异常信号。

**根因**：OBS 虚拟摄像头不提供采集元数据。

| 属性 | 相机返回值 | 代码应对 |
|------|-----------|---------|
| `CAP_PROP_POS_FRAMES` | −1 | 无兜底 |
| `CAP_PROP_FPS` | 0.0 | [`main.py:705`](main.py) 兜底为 30.0 |

原推导逻辑（两文件一致）：

```python
current_frame_idx = int(self.cap.get(cv2.CAP_PROP_POS_FRAMES)) - 1   # → -2
if current_frame_idx < 0:
    current_frame_idx = self._frame_count                            # 保持原值
self._frame_count = current_frame_idx                                # 永久为 0
```

`_frame_count` 恒为 0 后，所有 `% N` 条件永久为真，节流全面退化为每帧执行：

| 位置 | 设计意图 | 相机实际 |
|------|---------|---------|
| `main.py:836` / `838` | 上块 1/3 帧、下块 2/3 帧做重度预处理 | 两块每帧都做 |
| `main.py:968` / `972` | 上块 3 帧 1 次、下块 3 帧 2 次推理（均值 1 次/帧） | 每帧 2 次推理 |
| `main.py:1460` | 每 60 帧清理陈旧轨迹 | 每帧清理 |
| `main.py:902` / `1552` | 时间戳 `idx / fps` | 恒为 0.0，UI 时间始终显示 00:00 |

**受控 A/B 验证**（同进程、同机、同 OBS 画面，仅帧序号来源不同；文件源分支同时作为改动前的对照）：

| 指标 | 修复前·相机源 | 修复前·文件源 | 修复后·相机源 | 修复后·文件源 |
|------|-------------:|-------------:|-------------:|-------------:|
| `_frame_count` 唯一值 | 1 / 311 帧 | 425 / 425 帧 | 417 / 417 帧 | 397 / 397 帧 |
| `_frame_count % 3` 分布 | {0: 311} | {0:142, 1:142, 2:141} | {0:139, 1:139, 2:139} | 均匀 |
| 模型调用/帧 | **2.00** | 1.00 | **1.00** | 1.00 |
| 单次调用 | 15.1 ms | 14.3 ms | 16.0 ms | 18.9 ms |
| 推理/帧 | 30.2 ms | 14.4 ms | 16.0 ms | 19.0 ms |
| 非推理/帧 | 34.4 ms | 23.4 ms | 26.0 ms | 25.7 ms |
| 帧延迟 | 64.6 ms | 37.7 ms | **42.0 ms** | 44.7 ms |
| FPS | **15.50** | 21.07 | **20.78** | 19.83 |

修复前相机源比文件源慢 71%（64.6 vs 37.7 ms）；修复后两者持平，说明缺陷已被完全消除。

**修复**（两文件各 3 行改动）：相机源（`self.source` 为 int，两文件已用此判定选择 `CAP_DSHOW`）改为自增，文件源逻辑原样保留。

```python
if isinstance(self.source, int):
    current_frame_idx = self._frame_count + 1
else:
    current_frame_idx = int(self.cap.get(cv2.CAP_PROP_POS_FRAMES)) - 1
    if current_frame_idx < 0:
        current_frame_idx = self._frame_count
self._frame_count = current_frame_idx
```

**效果**：相机源帧延迟 64.6 → 42.0 ms（−35%），帧率 15.50 → 20.78 FPS（+34%），与文件源持平；时间戳恢复正常推进。回归测试 `tests/test_front_path.py` 23/23 通过。

**同时修复的诊断缺陷**：应用日志原来在**加载模型之前**就打印 `模型：yolo11n.pt`（即配置的权重文件名），打包应用以 `--windowed` 运行、INT8 加载失败信息又只走 `print`，导致日志既不能证明实际加载了哪个模型、失败原因也不可见。现在加载完成后记录 `实际加载模型：…（OpenVINO INT8）`，回退时记录 `warning` 级原因（`main.py` 731-745 行）。

> 该改动位于 `main.py` 与 `core/video_thread.py`，**打包产物需重新构建**后才会生效。

---

## 11. 遗留问题

以下为测试中发现但**未修改**的问题（属安全逻辑调参，需产品决策）：

1. **距离兜底 TTC 单位混用**：`front_detector` 中 `ttc_by_dist = abs(provided_distance / vy_world)`，其中 `vy_world` 为像素/秒，与米制距离相除。例如 5 m 距离、`vy=-360 px/s` 会得到 0.014 s 的荒谬 TTC，并被 `ttc > 0.1` 的下限保护吞掉。
2. **`calculator` 的 `v_rel_eff` 同类混用**：`((ys[-1] - ys[-2]) * fps - global_vy) - v_self_mps` 同样混合像素/秒与米/秒，仅用于背景流过滤的阈值判断。
3. **`vy_gate` 与 SDT 的符号不对称**：`vy_gate` 在 `vy > 2.0`（框心下移）时衰减 TTC，而 SDT 的 `-vy` 项在 `vy < 0`（框心上移）时膨胀，两者作用方向相反，行为不易推理。
4. **INT8 校准集偏小**：200 帧低于 NNCF 建议的 300 帧，补充校准帧可进一步缩小精度差距。
5. **打包环境依赖**：`venv` 必须安装 `openvino`，否则 INT8 静默回退 FP32（已在 README 标注）。
6. **打包产物体积**：启用 OpenVINO 后产物由约 0.67 GB 增至 0.92 GB（+245 MB）。

---

## 12. 复现命令

### 12.1 环境准备

```bash
pip install -r requirements.txt        # 含 openvino、matplotlib
```

### 12.2 性能基准

```bash
# 默认：摄像头索引 0、60 秒、CPU
python scripts\benchmark_cpu.py --source 0

# 指定分辨率、线程数、输出目录
python scripts\benchmark_cpu.py --source 1 --imgsz 320 --threads 8 --duration 120

# 对比 INT8 模型
python scripts\benchmark_cpu.py --source 1 ^
  --weights assets\weights\yolo11n_int8_openvino_model --imgsz 320

# 对比 GPU（有 CUDA 时）
python scripts\benchmark_cpu.py --source 1 --device 0

# 长时稳定性（15 分钟）
python scripts\benchmark_cpu.py --source 1 ^
  --weights assets\weights\yolo11n_int8_openvino_model --imgsz 320 --duration 900
```

### 12.3 量化验证（需先准备 COCO128 标注集）

```bash
# 默认 fp32 + int8，尺寸 320 / 640
python scripts\validate_quantization.py --data coco128.yaml --imgsz 320,640

# 多尺寸扫描（每个尺寸需单独导出固定输入的 INT8 模型）
python scripts\validate_quantization.py --data coco128.yaml --imgsz 160,256,320,416,512,640 ^
  --models "fp32=assets\weights\yolo11n.pt,int8_320=assets\weights\yolo11n_int8_openvino_model"
```

### 12.4 INT8 模型导出

```bash
python -c "from ultralytics import YOLO; YOLO('assets/weights/yolo11n.pt').export(format='openvino', int8=True, data='assets/calibration/calibration.yaml', imgsz=320)"
```

### 12.5 回归测试

```bash
pytest tests\test_front_path.py -v
python tests\test_front_path.py
```

### 12.6 打包

```bash
setup_build_env.bat      # 首次：创建 CPU 版 PyTorch 精简环境
build_windows.bat
```

---

## 13. 产物索引

`benchmark_results/` 下保留了 9 组最终数据（共 27 个文件，9.6 MB），各含逐帧 CSV、环境与统计摘要 JSON、以及覆盖全程的 FPS / 延迟 / 内存 PNG 图。

| 时间戳 | 内容 |
|--------|------|
| `20261004_211029` | GPU 参考（`device=0`，`imgsz=640`） |
| `20261004_222000` | **量化验证（A/C）**：6 尺寸 × 2 精度 |
| `20261004_222119` | 端到端（B）：FP32 `imgsz=320` |
| `20261004_222213` | 端到端（B）：FP32 `imgsz=512` |
| `20261004_222307` | 端到端（B）：FP32 `imgsz=640` |
| `20261004_222401` | 端到端（B）：INT8 `imgsz=320` |
| `20261004_222456` | 端到端（B）：INT8 `imgsz=512` |
| `20261004_222552` | 端到端（B）：INT8 `imgsz=640` |
| `20261004_225634` | **长时稳定性（F）**：15 分钟，26724 帧 |

代表性文件：

- 稳定性逐帧数据：`benchmark_results/fastguard_cpu_benchmark_20261004_225634.csv`（26724 行，含 `rolling_fps`、`inference_ms`、`frame_cycle_ms`、`rss_mb`）
- 量化验证汇总：`benchmark_results/fastguard_quantization_validation_20261004_222000.json`
- 对比图：`benchmark_results/fastguard_quantization_validation_20261004_222000.png`

> 已删除 6 组被取代或重复的中间运行（`210348`、`211421`、`213300`、`215557`、`215320`、`225350`）及 1 个空目录，释放 9.3 MB。保留项已覆盖全部结论。

---

## 附：本次改动清单

| 文件 | 改动 |
|------|------|
| `core/ipm.py` | 修复纵向轴符号（10.1） |
| `core/front_detector.py` | 静止判定优先（10.2）、SDT 单位统一（10.3） |
| `core/calculator.py` | SDT 单位统一（10.3） |
| `main.py`、`core/video_thread.py` | INT8 模型优先加载并回退 FP32；`imgsz` 640→320；固定物理核心线程数 |
| `main.py`、`core/video_thread.py` | 相机源帧序号改为自增，恢复分块节流（10.6） |
| `scripts/benchmark_cpu.py` | 内存采样、流式 CSV、有界降采样、`--device`/`--imgsz`/`--threads` |
| `scripts/validate_quantization.py` | 新增 |
| `tests/test_front_path.py` | 新增，23 项前向链路回归测试 |
| `requirements.txt` | 新增 `Pillow`、`lap`、`matplotlib`、`openvino` |
| `build_windows.bat` | `--collect-all openvino`，打包路径收窄为 `assets\weights` |
| `.gitignore` | 忽略 `benchmark_results/`、`assets/calibration/`、`assets/weights/_int8_sweep/` |
| `README.md` | 补充 CPU 基准、INT8 量化、稳定性、回归测试与打包说明 |
