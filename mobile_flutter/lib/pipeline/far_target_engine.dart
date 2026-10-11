/// 远距目标（长焦）检测：把**长焦镜头**看到的远处目标单独建成一组结果。
///
/// 与主摄链路（`inference_engine.dart` + `TtcCalculator`）的区别：
///
/// * 只关心**比阈值更远**的目标，因此**只标距离**，不做 TTC / 风险分级、
///   也不参与画面标框（避免把同一个远车画成两个互相漂移的框）；
/// * 用长焦自己的焦距测距（`焦距(像素) = 35mm等效焦距 / 36mm × 长焦图像宽度`），
///   否则同一像素尺寸会被换算成错误的距离；
/// * 主摄:长焦的推理配比按 **2:1** 节流（见 `InferenceEngine.telephotoEveryNMainFrames`），
///   因为长焦只是"补远远处"，没必要占用与主摄同等的算力。
library;

import '../core/distance_estimator.dart';
import '../core/ipm.dart';
import '../core/tracker.dart';

/// 单个远距目标（只带距离，不带风险分级）。
class FarTarget {
  const FarTarget({
    required this.id,
    required this.detection,
    required this.distanceM,
    this.lateralMeters,
    this.distanceSource,
  });

  final int id;

  /// 长焦画面里的几何（像素坐标，基于长焦帧尺寸）。
  final Detection detection;

  /// 估计距离（米）。
  final double distanceM;

  /// 相对长焦镜头光轴的横向偏移（米，右为正）；用于在俯视图里按角度摆放。
  final double? lateralMeters;

  /// 距离来源：`fused` / `height` / `width` / `ipm`。
  final String? distanceSource;
}

/// 长焦单帧结果。
class FarTargetSnapshot {
  const FarTargetSnapshot({
    required this.targets,
    required this.frameWidth,
    required this.frameHeight,
    required this.inferenceMs,
    required this.processed,
    this.nearCount = 0,
    this.thresholdM = 0.0,
  });

  /// 只包含"距离 ≥ 阈值"的目标。
  final List<FarTarget> targets;

  /// 长焦帧尺寸（俯视图据此换算横向偏移）。
  final int frameWidth;
  final int frameHeight;

  final double inferenceMs;
  final bool processed;

  /// 长焦画面里检出但**不够远**（未达阈值）的目标数，仅用于诊断。
  final int nearCount;

  /// 本帧使用的远距阈值（米），用于日志与界面展示。
  final double thresholdM;

  bool get hasTargets => targets.isNotEmpty;
}

/// 只保留远距目标：[thresholdM] 为距离阈值（米）。
///
/// 这是纯函数，便于在 `flutter test` 里直接验证"过滤 + 阈值边界"的行为。
List<FarTarget> filterFarTargets(List<FarTarget> all, double thresholdM) {
  return all.where((target) => target.distanceM >= thresholdM).toList();
}

/// 长焦检测引擎：航迹 + 测距 + 远距过滤。
///
/// **不做** TTC、不做风险分级；长焦航迹与主摄航迹完全独立
/// （两路画面尺寸/视角不同，混在一起关联会互相污染）。
class FarTargetEngine {
  FarTargetEngine({
    this.thresholdM = 40.0,
    SimpleTracker? tracker,
    this.estimator = const MonocularDistanceEstimator(),
  }) : tracker = tracker ?? SimpleTracker(minHits: 1);

  /// 远距阈值（米）。
  double thresholdM;

  final SimpleTracker tracker;
  final MonocularDistanceEstimator estimator;

  /// 处理一帧长焦画面（已完成推理的检测框）。
  ///
  /// [focalLengthPx] 是**长焦**的像素焦距；为 null 时退回 IPM 兜底
  /// （远距下 IPM 不可信，因此这种情况界面会提示远距数据仅供参照）。
  FarTargetSnapshot process({
    required List<Detection> detections,
    required int frameWidth,
    required int frameHeight,
    required double inferenceMs,
    required IpmTransformer ipm,
    double? focalLengthPx,
  }) {
    final tracks = tracker.update(detections, frameWidth, frameHeight);
    final all = <FarTarget>[];
    var nearCount = 0;

    for (final track in tracks) {
      if (track.misses != 0) {
        continue; // 本帧没真的看到它：不输出（航迹保留以便短暂遮挡后恢复）
      }
      final detection = track.detection;
      final estimate = estimateDistance(
        detection: detection,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        focalLengthPx: focalLengthPx,
        estimator: estimator,
        ipm: ipm,
      );
      final distance = estimate.meters;
      if (distance == null || !distance.isFinite || distance <= 0) {
        continue;
      }
      if (distance < thresholdM) {
        nearCount += 1; // 长焦也看得到的近处目标：主摄链路已经覆盖，这里不输出
        continue;
      }
      all.add(FarTarget(
        id: track.id,
        detection: detection,
        distanceM: distance,
        lateralMeters: estimateLateralOffset(
          centerX: detection.centerX,
          imageWidth: frameWidth.toDouble(),
          focalLengthPx: focalLengthPx,
          distanceM: distance,
        ),
        distanceSource: estimate.source,
      ));
    }

    return FarTargetSnapshot(
      targets: filterFarTargets(all, thresholdM),
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      inferenceMs: inferenceMs,
      processed: true,
      nearCount: nearCount,
      thresholdM: thresholdM,
    );
  }

  /// 清理已消失的长焦航迹。
  ///
  /// `SimpleTracker` 本身会在连续未命中超过 `maxMisses` 后删除航迹，
  /// 这里只是"长期没有长焦帧"时主动推进一次，避免航迹一直挂着。
  void cleanStale() => tracker.pruneStale();

  void reset() => tracker.reset();
}
