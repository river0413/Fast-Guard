/// 检测框**趋势平滑** —— 用前两帧的移动趋势外推到第三帧，再做平滑过渡。
///
/// 端上推理给出的检测框每帧都会有几像素的抖动（量化误差、NMS 边界波动、快速运动），
/// 直接绘制会看到框在"跳"。这里用一个常速（α-β）滤波器解决：
///
/// 1. **趋势**：`速度 = (上一帧输出 - 上上帧输出) / 帧间隔`，即前两帧的移动趋势；
///    `预测 = 上一帧输出 + 速度 × 帧间隔`，把框外推到当前（第三）帧；
/// 2. **过渡**：`输出 = 预测 + α × (本帧测量 - 预测)`，α 由「平滑强度」决定
///    （强度 0 → α = 1 → 输出 = 测量，即等价于关闭平滑）。
///
/// 两条重要性质（`test/core_algorithms_test.dart` 里有数值断言）：
/// * **稳态匀速运动不引入滞后**：此时"测量 - 预测"≈ 0，输出即测量值，只有抖动分量被
///   α 抑制（实测 ±4px 抖动被压到 ±0.7px）；速度突变后的最初几帧是过渡过程，
///   最多滞后约半个帧位移，随后收敛到 0（普通 EMA 会留下约 `(1-α)/α × 每帧位移` 的稳态滞后）；
/// * 速度用**平滑后的输出**更新（状态反馈），避免把单帧噪声放大成速度
///   （若直接用 速度 = 测量之差，预测就会变成 `2·m₂ - m₁`，反而放大抖动）。
///
/// 若测量偏离预测过大（换 ID、误检合并、遮挡后跳到别的目标），判定为"重定位"并
/// 直接吸附到测量值，防止框在画面上长距离滑行。
library;

import 'dart:math' as math;

import 'tracker.dart';

/// 平滑后的检测框（像素坐标）。
class SmoothedBox {
  const SmoothedBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.usedTrend,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  /// 本帧是否真的用上了趋势外推。
  ///
  /// `false` 表示直接采用本帧测量值：航迹刚出现（还没有趋势可用）、
  /// 时间基不可用（中断过久）、发生重定位，或平滑被关闭。
  final bool usedTrend;

  double get width => x2 - x1;
  double get height => y2 - y1;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;

  /// 还原成 [Detection]：只替换几何，保留模板的类别与置信度。
  Detection toDetection(Detection template) => Detection(
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        score: template.score,
        classId: template.classId,
        className: template.className,
      );

  @override
  String toString() => 'SmoothedBox(${x1.toStringAsFixed(1)}, ${y1.toStringAsFixed(1)}, '
      '${x2.toStringAsFixed(1)}, ${y2.toStringAsFixed(1)})${usedTrend ? ' [趋势]' : ''}';
}

/// 单条航迹的平滑状态：位置与速度都是 `[x1, y1, x2, y2]` 四维。
class _TrackMotion {
  _TrackMotion(List<double> position, this.frameIndex)
      : position = List<double>.of(position),
        velocity = List<double>.filled(4, 0.0);

  /// 上一帧的**输出**（而不是测量），作为滤波状态。
  List<double> position;

  /// 每帧位移（像素/帧）。
  List<double> velocity;

  int frameIndex;
}

/// 检测框趋势平滑器，按航迹 ID 维护状态。
class BoxTrendSmoother {
  BoxTrendSmoother({
    double strength = kDefaultStrength,
    this.maxJumpRatio = 0.30,
    this.maxGapFrames = 3,
  }) : _strength = strength.clamp(0.0, kMaxStrength);

  /// 默认平滑强度（对应 α = 0.45）。
  static const double kDefaultStrength = 0.55;

  /// 强度上限：α 至少保留 0.10，避免"完全信任外推"导致框自己漂走。
  static const double kMaxStrength = 0.90;

  /// 输出框的最小边长（像素），防止平滑把框压成一条线。
  static const double minBoxSide = 1.0;

  /// 测量相对预测的偏移超过"该比例 × 画面对角线"时判为重定位，直接吸附。
  final double maxJumpRatio;

  /// 相邻两次观测最多允许间隔多少帧；超过则重新起头（时间基不再可靠）。
  final int maxGapFrames;

  double _strength;
  final Map<int, _TrackMotion> _motions = <int, _TrackMotion>{};

  /// 平滑强度 0–0.9：0 = 关闭；越大越平滑（越依赖趋势外推）。
  double get strength => _strength;

  set strength(double value) {
    final clamped = value.clamp(0.0, kMaxStrength);
    if (clamped == _strength) {
      return;
    }
    _strength = clamped;
    // 强度变化（含开关平滑）后旧状态不再可比，重新累积即可（两帧内恢复）
    _motions.clear();
  }

  /// 本帧测量值的权重：强度 0.55 → α = 0.45（预测占 55%，测量占 45%）。
  double get alpha => (1.0 - _strength).clamp(0.10, 1.0);

  bool get enabled => _strength > 0;

  /// 当前有平滑状态的航迹数（诊断用）。
  int get stateCount => _motions.length;

  /// 用本帧测量值 [measurement] 更新 [trackId] 的状态并返回绘制用几何。
  ///
  /// [frameIndex] 必须是**推理帧序号**（随帧单调递增），帧间隔由它算出。
  SmoothedBox smooth({
    required int trackId,
    required Detection measurement,
    required int frameIndex,
    required double frameWidth,
    required double frameHeight,
  }) {
    final raw = <double>[
      measurement.x1,
      measurement.y1,
      measurement.x2,
      measurement.y2,
    ];

    if (!enabled) {
      _motions.remove(trackId);
      return _finalize(raw, frameWidth, frameHeight, usedTrend: false);
    }

    final motion = _motions[trackId];
    if (motion == null) {
      // 首次观测：只有一帧，还没有趋势可用
      _motions[trackId] = _TrackMotion(raw, frameIndex);
      return _finalize(raw, frameWidth, frameHeight, usedTrend: false);
    }

    final elapsed = frameIndex - motion.frameIndex;
    if (elapsed <= 0 || elapsed > maxGapFrames) {
      // 重复帧或中断过久：时间基失效，重新起头而不是外推
      _restart(motion, raw, frameIndex);
      return _finalize(raw, frameWidth, frameHeight, usedTrend: false);
    }

    final predicted = List<double>.generate(
      4,
      (index) => motion.position[index] + motion.velocity[index] * elapsed,
    );
    final residual = List<double>.generate(4, (index) => raw[index] - predicted[index]);

    final diagonal = math.sqrt(frameWidth * frameWidth + frameHeight * frameHeight);
    if (diagonal > 0 && _norm(residual) > diagonal * maxJumpRatio) {
      // 重定位：与其让框滑过去，不如直接吸附
      _restart(motion, raw, frameIndex);
      return _finalize(raw, frameWidth, frameHeight, usedTrend: false);
    }

    // 平滑过渡：从"趋势预测"按 α 回拉向本帧测量
    final output = List<double>.generate(
      4,
      (index) => predicted[index] + alpha * residual[index],
    );

    // 状态反馈：速度由平滑后的输出求得
    motion.velocity = List<double>.generate(
      4,
      (index) => (output[index] - motion.position[index]) / elapsed,
    );
    motion.position = List<double>.of(output);
    motion.frameIndex = frameIndex;

    return _finalize(output, frameWidth, frameHeight, usedTrend: true);
  }

  /// 清掉已消失航迹的状态，避免长时间运行内存增长。
  void retain(Set<int> activeTrackIds) {
    _motions.removeWhere((id, _) => !activeTrackIds.contains(id));
  }

  void reset() => _motions.clear();

  static void _restart(_TrackMotion motion, List<double> raw, int frameIndex) {
    motion.position = List<double>.of(raw);
    motion.velocity = List<double>.filled(4, 0.0);
    motion.frameIndex = frameIndex;
  }

  static double _norm(List<double> values) {
    var sum = 0.0;
    for (final value in values) {
      sum += value * value;
    }
    return math.sqrt(sum);
  }

  /// 钳制到画面内，并保证最小边长。
  static SmoothedBox _finalize(
    List<double> box,
    double frameWidth,
    double frameHeight, {
    required bool usedTrend,
  }) {
    final (x1, x2) = _clampAxis(box[0], box[2], frameWidth);
    final (y1, y2) = _clampAxis(box[1], box[3], frameHeight);
    return SmoothedBox(
      x1: x1,
      y1: y1,
      x2: x2,
      y2: y2,
      usedTrend: usedTrend,
    );
  }

  /// 把 `[low, high]` 钳到 `[0, limit]`，并保证 `high - low >= minBoxSide`。
  static (double, double) _clampAxis(double low, double high, double limit) {
    if (limit <= 0) {
      return (low, high);
    }
    var from = low.clamp(0.0, limit);
    var to = high.clamp(0.0, limit);
    if (to - from >= minBoxSide) {
      return (from, to);
    }
    final center = (from + to) / 2;
    from = center - minBoxSide / 2;
    to = center + minBoxSide / 2;
    if (from < 0) {
      to -= from;
      from = 0.0;
    }
    if (to > limit) {
      from -= to - limit;
      to = limit;
    }
    return (from < 0 ? 0.0 : from, to);
  }
}
