/// 单目测距：用**真实物体尺寸 + 相机焦距**按针孔模型估算距离。
///
///     距离(米) = 真实尺寸(米) × 焦距(像素) / 目标像素尺寸
///
/// 相比"逆透视(IPM) + 猜测相机安装高度/俯仰角"，本方法不需要猜安装姿态，但要求：
///   1. 已知目标类别的典型真实尺寸（见 [objectMetrics]）；
///   2. 已知相机焦距(像素)（由 `CameraOptics.focalLengthPixels` 从设备读取）；
///   3. 目标大致正对/背对镜头。
///
/// **高度与宽度结合**：
/// 同一个框可以按"真实高度 / 框高"和"真实宽度 / 框宽"各算一次距离。
/// 单目测量中像素尺寸越大、相对误差越小，因此这里按**像素尺寸加权融合**两路结果，
/// 让更可信的那一维自动占主导；两路差距过大时给出"视角异常"提示（例如只看到车侧）。
library;

import 'dart:math' as math;

import 'ipm.dart';
import 'tracker.dart';

/// 目标典型真实尺寸（米）。
class ObjectMetrics {
  const ObjectMetrics({
    required this.heightM,
    required this.widthM,
    this.lengthsM = const <double>[],
    this.note = '',
  });

  /// 真实高度（米）——与检测框**高**对应。
  final double heightM;

  /// 真实宽度（米）——与检测框**宽**对应。
  final double widthM;

  /// 真实长度候选（米，升序）。公交车为离散车型，卡车为 5–15m 区间的等距取值，
  /// 轿车固定 5m。按框的像素长宽比从中选一个（见 [MonocularDistanceEstimator]）。
  final List<double> lengthsM;

  final String note;
}

/// 各类别典型真实尺寸（米）。
///
/// * **高度**采用需求方给定值：公交车 2.5、卡车 3.0、轿车 1.75、
///   **两轮车（自行车/摩托车）0.5**；行人用更稳定的量：身高 1.70
///   （远比肩宽稳定）。
/// * **宽度**另取一组参考值（中国道路车辆外廓限宽 2.55m；轿车约 1.80m；
///   **两轮车 0.3m**）。
/// * **长度**用于由像素长宽比反推偏航角：轿车固定 5m；公交车为离散车型；
///   卡车为 5–15m 五档；**两轮车 1.75–2.5m 四档**。
///
/// 数值集中在此处，便于按实际车型标定后统一调整。
const Map<int, ObjectMetrics> objectMetrics = <int, ObjectMetrics>{
  0: ObjectMetrics(heightM: 1.70, widthM: 0.50, lengthsM: <double>[0.30], note: '行人：身高比肩宽稳定得多'),
  1: ObjectMetrics(
    heightM: 0.50,
    widthM: 0.30,
    lengthsM: <double>[1.75, 2.00, 2.25, 2.50],
    note: '自行车（两轮车大类）：高 0.5 / 宽 0.3 / 长 1.75–2.5（需求给定，均为车身，不含骑行者）',
  ),
  2: ObjectMetrics(heightM: 1.75, widthM: 1.80, lengthsM: <double>[5.0], note: '轿车：高度 1.75（需求给定）'),
  3: ObjectMetrics(
    heightM: 0.50,
    widthM: 0.30,
    lengthsM: <double>[1.75, 2.00, 2.25, 2.50],
    note: '摩托车（两轮车大类，含电动两轮车）：尺寸与自行车同，均为车身而不含骑行者',
  ),
  5: ObjectMetrics(heightM: 2.50, widthM: 2.55, lengthsM: <double>[6, 8, 10, 12, 18], note: '公交车：高度 2.5（需求给定）'),
  7: ObjectMetrics(heightM: 3.00, widthM: 2.55, lengthsM: <double>[5, 7.5, 10, 12.5, 15], note: '卡车：高度 3.0（需求给定），长度 5–15m'),
};

/// 两轮车大类（自行车 + 摩托车）的类别 ID，供界面/文档引用。
const Set<int> twoWheelerClassIds = <int>{1, 3};

/// 单维（高或宽）的测距结果。
class AxisEstimate {
  const AxisEstimate({
    required this.axis,
    required this.realSizeM,
    required this.pixelSize,
    required this.meters,
  });

  /// `height` 或 `width`。
  final String axis;
  final double realSizeM;
  final double pixelSize;
  final double meters;

  @override
  String toString() => '$axis: ${realSizeM.toStringAsFixed(2)}m / '
      '${pixelSize.toStringAsFixed(1)}px = ${meters.toStringAsFixed(1)}m';
}

/// 测距结果（已融合高度/宽度两路）。
class DistanceEstimate {
  const DistanceEstimate({
    required this.meters,
    required this.source,
    this.axes = const <AxisEstimate>[],
    this.warning,
    this.lengthM,
    this.yawDeg,
  });

  /// 由像素长宽比选出的真实车长（米）；正对/背对无法判断时为 null。
  final double? lengthM;

  /// 推算的偏航角（度）：0 = 正对/背对镜头，90 = 正侧面。
  final double? yawDeg;

  /// 融合后的距离（米）。
  final double meters;

  /// `fused` = 高低两路加权融合；`height` / `width` = 仅单路可用。
  final String source;

  /// 各维的原始估算（便于排查与展示）。
  final List<AxisEstimate> axes;

  /// 可能不可靠时的提示（例如疑似侧向视角）。
  final String? warning;

  /// 两路是否一致（相对差 < 30%）。
  bool get axesAgree {
    if (axes.length < 2) {
      return true;
    }
    final maxM = axes.map((a) => a.meters).reduce((a, b) => a > b ? a : b);
    final minM = axes.map((a) => a.meters).reduce((a, b) => a < b ? a : b);
    return (maxM - minM) / minM < MonocularDistanceEstimator.disagreementThreshold;
  }

  @override
  String toString() => '${meters.toStringAsFixed(1)}m ($source)';
}

class MonocularDistanceEstimator {
  const MonocularDistanceEstimator();

  /// 可信距离上限（米），超过视为不可靠。
  static const double maxReliableMeters = 120.0;

  /// 目标像素尺寸过小则噪声过大，不予估算。
  static const double minPixelSize = 8.0;

  /// 两路结果相对差超过该比例时，给出"视角异常"提示。
  static const double disagreementThreshold = 0.30;

  /// 框边缘距画面边界不超过该像素数，视为被截断。
  static const double truncationMarginPx = 2.0;

  /// 用 [detection] 与焦距(像素) [focalLengthPx] 估算距离。
  ///
  /// 同时用框高与框宽各算一次，再按像素尺寸加权融合。
  DistanceEstimate? estimate(
    Detection detection, {
    required double focalLengthPx,
    int? frameWidth,
    int? frameHeight,
  }) {
    if (focalLengthPx <= 0) {
      return null;
    }
    final metrics = objectMetrics[detection.classId];
    if (metrics == null) {
      return null; // 未标定尺寸的类别（红绿灯/标志牌等）不参与测距
    }

    final axes = <AxisEstimate>[];

    void addAxis(String axis, double realSize, double pixelSize) {
      if (realSize <= 0 || pixelSize < minPixelSize) {
        return;
      }
      final meters = realSize * focalLengthPx / pixelSize;
      if (meters <= 0 || !meters.isFinite || meters > maxReliableMeters) {
        return;
      }
      axes.add(AxisEstimate(
        axis: axis,
        realSizeM: realSize,
        pixelSize: pixelSize,
        meters: meters,
      ));
    }

    // 框顶/底贴着画面边缘 => 目标被截断，框高偏小，高度这一路不可信
    final heightTruncated = frameHeight != null &&
        (detection.y1 <= truncationMarginPx || detection.y2 >= frameHeight - truncationMarginPx);

    // 三维模型：车体 = 长L × 宽W × 高H 的长方体，偏航角 θ 下水平投影宽度为
    //   E(θ) = W·cosθ + L·sinθ，而高度不随偏航变化。
    // 因此：先用高度得到（与偏航无关的）距离，再由像素长宽比 a = 框宽/框高
    // 反推水平真实投影 E = a·H，据此从长度候选中选车长并解出偏航角，
    // 宽度一路改用「受 [W, √(W²+L²)] 约束的有效宽度」，不再把侧面当成正面宽度。
    double? lengthM;
    double? yawDeg;
    var effectiveWidth = metrics.widthM;
    String? truncationWarning;

    if (!heightTruncated) {
      addAxis('height', metrics.heightM, detection.height);
    }
    final lengths = metrics.lengthsM;
    if (lengths.isNotEmpty && detection.height >= minPixelSize) {
      if (!heightTruncated) {
        final span = detection.width / detection.height * metrics.heightM; // E = a·H（米）
        final fit = _fitFootprint(metrics.widthM, lengths, span);
        effectiveWidth = fit.effectiveWidth;
        lengthM = fit.lengthM;
        yawDeg = fit.yawDeg;
      } else {
        // 高度被截断、无法由比例反推：取 [W, √(W²+L中²)] 的中点，并提示不确定
        final midLength = lengths[lengths.length ~/ 2];
        final maxSpan = math.sqrt(metrics.widthM * metrics.widthM + midLength * midLength);
        effectiveWidth = (metrics.widthM + maxSpan) / 2;
        truncationWarning = '目标顶/底被画面截断，仅按宽度估算（视角未知，不确定度大）';
      }
    }
    addAxis('width', effectiveWidth, detection.width);

    if (axes.isEmpty) {
      return null;
    }

    // 按像素尺寸加权：像素越多，相对测量误差越小，权重越高
    final totalWeight = axes.fold<double>(0, (sum, axis) => sum + axis.pixelSize);
    final fused = axes.fold<double>(0, (sum, axis) => sum + axis.meters * axis.pixelSize) / totalWeight;

    String? warning = truncationWarning;
    if (axes.length >= 2) {
      final maxM = axes.map((a) => a.meters).reduce((a, b) => a > b ? a : b);
      final minM = axes.map((a) => a.meters).reduce((a, b) => a < b ? a : b);
      final relativeGap = (maxM - minM) / minM;
      if (relativeGap > disagreementThreshold) {
        warning =
            '高/宽两路差异 ${(relativeGap * 100).toStringAsFixed(0)}%（疑似侧向视角或部分遮挡）';
      }
    }

    return DistanceEstimate(
      meters: fused,
      source: axes.length >= 2 ? 'fused' : axes.first.axis,
      axes: axes,
      warning: warning,
      lengthM: lengthM,
      yawDeg: yawDeg,
    );
  }

  /// 由水平投影宽度 [span]（米）选车长并求偏航角。
  ///
  /// 车长取候选中**不小于** √(span²−W²) 的最小值（span ≤ √(W²+L²) 才可能成立），
  /// 超出最大候选时钳到最大值（此时有效宽度被限制，宽度一路会把距离拉近，偏安全）。
  /// 偏航角取 E(θ)=span 的较小解（更偏正对）。
  static ({double effectiveWidth, double? lengthM, double? yawDeg}) _fitFootprint(
    double width,
    List<double> lengths,
    double span,
  ) {
    if (span <= width) {
      return (effectiveWidth: width, lengthM: null, yawDeg: 0.0);
    }
    final minLength = math.sqrt(span * span - width * width);
    var length = lengths.last;
    for (final candidate in lengths) {
      if (candidate >= minLength) {
        length = candidate;
        break;
      }
    }
    final maxSpan = math.sqrt(width * width + length * length);
    final alpha = math.atan2(length, width);
    if (span >= maxSpan) {
      return (effectiveWidth: maxSpan, lengthM: length, yawDeg: alpha * 180 / math.pi);
    }
    final theta = alpha - math.acos(span / maxSpan);
    return (effectiveWidth: span, lengthM: length, yawDeg: theta * 180 / math.pi);
  }

  /// 目标相对镜头光轴的**横向偏移（米）**：`X = (u - cx) / f × 距离`。
  ///
  /// 这是构建俯视图（BEV）所需的关键量。相比经典 IPM（需要预先知道相机安装高度与
  /// 俯仰角），这里直接用"该目标已估出的距离 + 真实焦距"换算横向位置，
  /// 因此**不需要猜测手机在车内的安装姿态**。
  ///
  /// 前提：目标位于地面附近、且相机没有明显横滚（roll）；手机横屏正对前方时成立。
  static double? lateralOffsetMeters({
    required double centerX,
    required double imageWidth,
    required double focalLengthPx,
    required double distanceM,
  }) {
    if (focalLengthPx <= 0 || imageWidth <= 0 || distanceM <= 0) {
      return null;
    }
    final principalPointX = imageWidth / 2.0;
    return (centerX - principalPointX) / focalLengthPx * distanceM;
  }
}

/// 测距的**唯一入口**（端上管线与绘制平滑层共用，保证两处结果一致）：
/// 优先针孔模型（真实尺寸 + 真实焦距，高低两路融合），拿不到焦距时回退 IPM。
({double? meters, String? source, double? lengthM, double? yawDeg}) estimateDistance({
  required Detection detection,
  required int frameWidth,
  required int frameHeight,
  required IpmTransformer ipm,
  double? focalLengthPx,
  MonocularDistanceEstimator estimator = const MonocularDistanceEstimator(),
}) {
  double? meters;
  String? source;
  double? lengthM;
  double? yawDeg;
  if (focalLengthPx != null) {
    final estimate = estimator.estimate(
      detection,
      focalLengthPx: focalLengthPx,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
    );
    if (estimate != null) {
      meters = estimate.meters;
      source = estimate.source;
      lengthM = estimate.lengthM;
      yawDeg = estimate.yawDeg;
    }
  }
  meters ??= ipm.distanceFromBottom(detection.centerX, detection.y2, frameWidth, frameHeight);
  source ??= meters != null ? 'ipm' : null;
  return (meters: meters, source: source, lengthM: lengthM, yawDeg: yawDeg);
}

/// 横向偏移的**唯一入口**（俯视图定位用）：`X = (u - cx) / f × 距离`。
///
/// 参数缺失（未取到焦距 / 未估出距离）时返回 null。
double? estimateLateralOffset({
  required double centerX,
  required double imageWidth,
  required double? focalLengthPx,
  required double? distanceM,
}) {
  final focal = focalLengthPx;
  final distance = distanceM;
  if (focal == null || distance == null) {
    return null;
  }
  return MonocularDistanceEstimator.lateralOffsetMeters(
    centerX: centerX,
    imageWidth: imageWidth,
    focalLengthPx: focal,
    distanceM: distance,
  );
}
