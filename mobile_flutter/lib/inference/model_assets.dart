/// 可用的端上模型资产（FP32 / INT8 量化）。
///
/// 两个模型都是同一个 ONNX 端点（输入 `images`、输出 `output0`），只是权重与激活的精度不同：
///
/// | 资产 | 体积 | 精度 | 说明 |
/// |---|---|---|---|
/// | [kModelAssetFp32] | 10.1 MB | FP32 | 默认；导出时 `dynamic=True`，输入尺寸可运行时切换 |
/// | [kModelAssetInt8] | 4.1 MB | INT8(QDQ) | 88 个 Conv 中量化 63 个，**检测头保持 FP32** |
///
/// `kModelAssetInt8` 的具体配方（不要随意改，见 `tools/export_int8_onnx.py`）：
///
/// * 静态量化 `QDQ`，校准集 = `assets/calibration/images` 的 200 帧，`CalibrationMethod.MinMax`；
/// * **只量化 backbone/neck 的 Conv，`/model.23/`（检测头）整体排除、保持 FP32**。
///
/// 为什么必须排除检测头：检测头的输出是**后处理前的 logits**，其取值范围完全由画面里
/// 有无目标决定。用"几乎全是远景小目标"的帧做校准，得到的激活范围很窄，一旦出现
/// 近处大目标就会被**截断到量程上限**，表现是**所有高置信度都变成 0.5**
/// （sigmoid(0)）——实测 Ultralytics 默认的 INT8 导出（88/88 个 Conv 全量化）
/// 在 bus.jpg 上把 0.846 的公交车与 0.811 的行人**全部**变成 0.500，
/// 而排除检测头后，留出图像（zidane.jpg，不在校准/验证集内）上的输出与 FP32
/// 一致到小数点后三位（0.901 / 0.889 / 0.872 / 0.867 vs FP32 的 0.890 / 0.880 / 0.879 / 0.867）。
library;

/// FP32 模型（默认，输入尺寸可切换）。
const String kModelAssetFp32 = 'assets/yolo11n.onnx';

/// INT8 量化模型（更小；检测头保持 FP32）。
const String kModelAssetInt8 = 'assets/yolo11n_int8.onnx';

/// 按设置选择模型资产。
String modelAssetFor({required bool int8}) => int8 ? kModelAssetInt8 : kModelAssetFp32;

/// 界面展示用的模型元信息（体积取自导出产物，见 `tools/export_int8_onnx.py`）。
const Map<String, String> kModelAssetLabels = <String, String>{
  kModelAssetFp32: 'FP32 · 10.1 MB',
  kModelAssetInt8: 'INT8 · 4.1 MB',
};

/// 未知资产时的兜底标签。
const String kModelAssetUnknownLabel = '未知模型';
