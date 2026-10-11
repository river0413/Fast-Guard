/// 端上推理：直接用 ONNX Runtime 跑 YOLO11n。
///
/// 模型来自 Ultralytics 导出（见 `mobile/README.md`）：
///   输入  `images`   float32 [1, 3, S, S]（S = 320/416/512/640）
///   输出  `output0`  float32 [1, 84, N]（84 = 4 框 + 80 类；N = 2100 @ 320）
///
/// 可用两种精度的同一模型（见 [model_assets.dart]）：FP32 与 INT8(QDQ 量化)。
/// 两者都是**动态输入**，因此 [inputSize] 可运行时切换。
///
/// 预处理（letterbox）与后处理（置信度过滤 + 逐类 NMS + 反变换）都在本文件实现，
/// 因此调整推理图片大小只需要改 [inputSize]，不必重新导出模型。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../core/tracker.dart';
import 'model_assets.dart';

/// COCO 80 类名称（索引与模型输出一致）。
const List<String> cocoClassNames = <String>[
  'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck', 'boat',
  'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench', 'bird', 'cat', 'dog',
  'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra', 'giraffe', 'backpack', 'umbrella',
  'handbag', 'tie', 'suitcase', 'frisbee', 'skis', 'snowboard', 'sports ball', 'kite',
  'baseball bat', 'baseball glove', 'skateboard', 'surfboard', 'tennis racket', 'bottle',
  'wine glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich',
  'orange', 'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
  'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse', 'remote',
  'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink', 'refrigerator', 'book',
  'clock', 'vase', 'scissors', 'teddy bear', 'hair drier', 'toothbrush',
];

/// 关注的类别 → 中文名（其余类别不参与预警，减少误报）。
///
/// 与桌面端 `main.py` 的 `MAIN_TARGET_CLASSES`（行人 / 轿车 / 卡车 / 公交车）相比，
/// 移动端额外把 **两轮车大类**（自行车 + 摩托车，含电动两轮车）纳入关注类别：
/// 两轮车在路口最常见的冲突对象之一，漏检代价远高于多算两次测距。
const Map<int, String> focusClassNames = <int, String>{
  0: '行人',
  1: '自行车',
  2: '轿车',
  3: '摩托车',
  5: '公交车',
  7: '卡车',
};

/// COCO 中全部交通参与者（设置栏开启"显示全部 80 类"时可参考）。
const Map<int, String> trafficClassNames = <int, String>{
  0: '行人',
  1: '自行车',
  2: '轿车',
  3: '摩托车',
  5: '公交车',
  7: '卡车',
  9: '红绿灯',
  11: '停车标志',
};

/// letterbox 之后的坐标映射关系（用于把检测框还原到原图）。
class _Letterbox {
  const _Letterbox({required this.scale, required this.padX, required this.padY});
  final double scale;
  final double padX;
  final double padY;
}

class YoloOnnxDetector {
  YoloOnnxDetector({
    this.inputSize = 320,
    this.confThreshold = 0.35,
    this.iouThreshold = 0.45,
    this.maxDetections = 60,
    this.focusOnly = true,
  });

  /// 推理图片大小（必须是 32 的倍数；模型为动态输入，可运行时调整）。
  int inputSize;
  double confThreshold;
  double iouThreshold;
  int maxDetections;

  /// 只保留交通参与者类别（行人/车辆等），过滤掉杯子、椅子之类的无关目标。
  bool focusOnly;

  OnnxRuntime? _ort;
  OrtSession? _session;

  /// 张量名固定取自导出的模型（已用 onnx 读取确认）：
  ///   输入 `images`   float32 [1,3,S,S]
  ///   输出 `output0`  float32 [1,84,N]
  ///
  /// 注意：**不要**改用 `OrtSession.getInputInfo()/getOutputInfo()` 去自动发现名字。
  /// flutter_onnxruntime 1.9.0 的这两个方法内部会构造 `ai.onnxruntime.NodeInfo`，
  /// 而它打包的 ONNX Runtime 1.28.0 已无该构造函数，调用会抛
  /// `NoSuchMethodError` 并触发**无法捕获的原生 SIGABRT**（真机实测：应用启动即闪退）。
  static const String _inputName = 'images';
  static const String _outputName = 'output0';

  bool _loaded = false;
  String? _lastError;

  /// 当前已加载的模型资产（用于判断"切换模型精度"是否需要重新加载）。
  String? _loadedAssetKey;

  bool get isLoaded => _loaded;
  String? get lastError => _lastError;
  String? get loadedAssetKey => _loadedAssetKey;

  /// 加载模型（asset 会被复制到临时目录后交给 ONNX Runtime）。
  ///
  /// 传入与当前不同的 [assetKey] 时会先关闭旧会话再加载新模型；
  /// 传入相同的 key 则直接返回（重复调用无副作用）。
  Future<void> load({String assetKey = kModelAssetFp32}) async {
    if (_loaded && _loadedAssetKey == assetKey) {
      return;
    }
    if (_loaded) {
      await dispose();
    }
    try {
      _ort ??= OnnxRuntime();
      _session = await _ort!.createSessionFromAsset(assetKey);
      _loaded = true;
      _loadedAssetKey = assetKey;
      _lastError = null;
    } catch (error) {
      _loaded = false;
      _loadedAssetKey = null;
      _lastError = '模型加载失败：$error';
      rethrow;
    }
  }

  /// 对一帧 RGB 图像做推理，返回过滤后的检测框（坐标已还原到原图）。
  ///
  /// [rgb] 为紧凑排列的 RGB888 数据，长度必须是 width * height * 3。
  Future<List<Detection>> detect(Uint8List rgb, int width, int height) async {
    final session = _session;
    if (session == null || !_loaded) {
      throw StateError('推理模型尚未加载，请先调用 load()');
    }
    if (rgb.length < width * height * 3) {
      throw ArgumentError('RGB 数据长度不足：${rgb.length} < ${width * height * 3}');
    }

    final size = inputSize;
    final letterbox = _computeLetterbox(width, height, size);
    final input = _preprocess(rgb, width, height, size, letterbox);

    final inputValue = await OrtValue.fromList(input, <int>[1, 3, size, size]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run(<String, OrtValue>{_inputName: inputValue});
      final output = outputs[_outputName];
      if (output == null) {
        throw StateError('模型输出中没有 $_outputName');
      }
      final raw = await output.asFlattenedList();
      final detections = _postprocess(raw, width, height, letterbox);
      return detections;
    } finally {
      await inputValue.dispose();
      if (outputs != null) {
        for (final value in outputs.values) {
          await value.dispose();
        }
      }
    }
  }

  Future<void> dispose() async {
    await _session?.close();
    _session = null;
    _loaded = false;
    _loadedAssetKey = null;
  }

  // ------------------------------------------------------------------ 预处理
  static _Letterbox _computeLetterbox(int width, int height, int size) {
    final scale = math.min(size / width, size / height);
    final newWidth = (width * scale).round();
    final newHeight = (height * scale).round();
    return _Letterbox(
      scale: scale,
      padX: (size - newWidth) / 2.0,
      padY: (size - newHeight) / 2.0,
    );
  }

  /// letterbox + RGB → NCHW float32（0..1），边缘用 114/255 填充（与 Ultralytics 一致）。
  static Float32List _preprocess(
    Uint8List rgb,
    int width,
    int height,
    int size,
    _Letterbox letterbox,
  ) {
    const padValue = 114.0 / 255.0;
    final plane = size * size;
    final tensor = Float32List(3 * plane);
    tensor.fillRange(0, tensor.length, padValue);

    final targetWidth = (width * letterbox.scale).round();
    final targetHeight = (height * letterbox.scale).round();
    final offsetX = ((size - targetWidth) / 2.0).round();
    final offsetY = ((size - targetHeight) / 2.0).round();

    for (var ty = 0; ty < targetHeight; ty++) {
      // 双线性采样的源坐标
      final sourceY = (ty + 0.5) / letterbox.scale - 0.5;
      final y0 = sourceY.floor().clamp(0, height - 1);
      final y1 = (y0 + 1).clamp(0, height - 1);
      final wy = (sourceY - y0).clamp(0.0, 1.0);

      for (var tx = 0; tx < targetWidth; tx++) {
        final sourceX = (tx + 0.5) / letterbox.scale - 0.5;
        final x0 = sourceX.floor().clamp(0, width - 1);
        final x1 = (x0 + 1).clamp(0, width - 1);
        final wx = (sourceX - x0).clamp(0.0, 1.0);

        final i00 = (y0 * width + x0) * 3;
        final i01 = (y0 * width + x1) * 3;
        final i10 = (y1 * width + x0) * 3;
        final i11 = (y1 * width + x1) * 3;

        final destination = (offsetY + ty) * size + (offsetX + tx);
        for (var channel = 0; channel < 3; channel++) {
          final top = rgb[i00 + channel] * (1 - wx) + rgb[i01 + channel] * wx;
          final bottom = rgb[i10 + channel] * (1 - wx) + rgb[i11 + channel] * wx;
          final value = (top * (1 - wy) + bottom * wy) / 255.0;
          tensor[channel * plane + destination] = value;
        }
      }
    }
    return tensor;
  }

  // ------------------------------------------------------------------ 后处理
  /// 解析 [1, 84, N] 输出 → 置信度过滤 → 逐类 NMS → 反 letterbox。
  List<Detection> _postprocess(
    List<dynamic> raw,
    int frameWidth,
    int frameHeight,
    _Letterbox letterbox,
  ) {
    final attributes = 4 + cocoClassNames.length; // 84
    if (raw.isEmpty || raw.length < attributes || raw.length % attributes != 0) {
      return const <Detection>[];
    }
    final anchors = raw.length ~/ attributes;

    double valueAt(int attribute, int anchor) =>
        (raw[attribute * anchors + anchor] as num).toDouble();

    final candidates = <Detection>[];
    for (var anchor = 0; anchor < anchors; anchor++) {
      // 找最大类别得分（YOLO11 检测头输出已过 sigmoid）
      var bestClass = -1;
      var bestScore = confThreshold;
      for (var c = 0; c < cocoClassNames.length; c++) {
        final score = valueAt(4 + c, anchor);
        if (score > bestScore) {
          bestScore = score;
          bestClass = c;
        }
      }
      if (bestClass < 0) {
        continue;
      }
      if (focusOnly && !focusClassNames.containsKey(bestClass)) {
        continue;
      }

      // 输出为 cx, cy, w, h（相对输入尺寸的像素值）
      final cx = valueAt(0, anchor);
      final cy = valueAt(1, anchor);
      final w = valueAt(2, anchor);
      final h = valueAt(3, anchor);

      // 反 letterbox：先减 padding，再除以缩放比例
      final left = (cx - w / 2 - letterbox.padX) / letterbox.scale;
      final top = (cy - h / 2 - letterbox.padY) / letterbox.scale;
      final right = (cx + w / 2 - letterbox.padX) / letterbox.scale;
      final bottom = (cy + h / 2 - letterbox.padY) / letterbox.scale;

      final x1 = left.clamp(0.0, frameWidth.toDouble());
      final y1 = top.clamp(0.0, frameHeight.toDouble());
      final x2 = right.clamp(0.0, frameWidth.toDouble());
      final y2 = bottom.clamp(0.0, frameHeight.toDouble());
      if (x2 - x1 < 4 || y2 - y1 < 4) {
        continue; // 过小，忽略
      }

      candidates.add(Detection(
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        score: bestScore,
        classId: bestClass,
        className: focusClassNames[bestClass] ?? cocoClassNames[bestClass],
      ));
    }

    final kept = _nms(candidates);
    kept.sort((a, b) => b.score.compareTo(a.score));
    return kept.length > maxDetections ? kept.sublist(0, maxDetections) : kept;
  }

  /// 逐类非极大值抑制。
  List<Detection> _nms(List<Detection> detections) {
    final result = <Detection>[];
    final byClass = <int, List<Detection>>{};
    for (final detection in detections) {
      byClass.putIfAbsent(detection.classId, () => <Detection>[]).add(detection);
    }
    for (final group in byClass.values) {
      group.sort((a, b) => b.score.compareTo(a.score));
      final suppressed = List<bool>.filled(group.length, false);
      for (var i = 0; i < group.length; i++) {
        if (suppressed[i]) {
          continue;
        }
        result.add(group[i]);
        for (var j = i + 1; j < group.length; j++) {
          if (suppressed[j]) {
            continue;
          }
          if (group[i].iou(group[j]) > iouThreshold) {
            suppressed[j] = true;
          }
        }
      }
    }
    return result;
  }
}
