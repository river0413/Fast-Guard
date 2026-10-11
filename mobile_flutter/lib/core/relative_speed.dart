/// 相对速度估计 —— 直接用 **TTC 与距离**反推接近速度。
///
///     接近速度 ≈ 距离 ÷ TTC
///
/// 为什么用 TTC 而不是再算一遍差分：`TtcCalculator` 已经在做"宽度增长率 → TTC"的
/// 估计，并对历史做了中断容忍与平滑；再独立算一遍像素差分只会引入第二套互相打架的
/// 时间基。这里只做一次除法 + EMA 平滑，**不参与风险分级**（分级仍由 TTC 决定）。
///
/// 符号约定：返回值为**接近速度**（m/s），正数表示正在靠近本车，0 表示未在接近。
library;

/// 相对速度估计器（按航迹 ID 维护状态）。
class RelativeSpeedEstimator {
  RelativeSpeedEstimator({
    this.emaAlpha = 0.35,
    this.safeTtc = 99.0,
    this.maxFrameGap = 3,
    this.maxReasonableMps = 80.0,
  });

  /// EMA 平滑系数（0–1，越大越跟手）。
  final double emaAlpha;

  /// 与 `TtcCalculator.safeTtc` 一致：等于该值表示无碰撞风险。
  final double safeTtc;

  /// 中断容忍帧数（与 TTC 计算器保持一致），超过则视为新目标重新累积。
  final int maxFrameGap;

  /// 合理速度上限（m/s，≈288 km/h）：超过视为测量噪声，直接钳位。
  final double maxReasonableMps;

  final Map<int, double> _smoothed = <int, double>{};
  final Map<int, int> _lastFrame = <int, int>{};

  /// 用本帧的 [distance]（米）与 [ttc]（秒）更新，返回平滑后的接近速度（m/s）。
  double update({
    required int trackId,
    required int frameIndex,
    required double? distance,
    required double ttc,
  }) {
    final last = _lastFrame[trackId];
    if (last != null && (frameIndex - last) > maxFrameGap) {
      // 中断过久：旧的接近速度不再可信，从本帧重新起头
      _smoothed.remove(trackId);
    }
    _lastFrame[trackId] = frameIndex;

    var instant = 0.0;
    if (distance != null && distance > 0 && ttc > 0 && ttc < safeTtc) {
      instant = distance / ttc;
      if (!instant.isFinite) {
        instant = 0.0;
      }
      if (instant > maxReasonableMps) {
        instant = maxReasonableMps;
      }
    }

    final previous = _smoothed[trackId];
    final value = previous == null ? instant : emaAlpha * instant + (1 - emaAlpha) * previous;
    _smoothed[trackId] = value;
    return value;
  }

  /// 已平滑的接近速度（未估计过时返回 0）。
  double speedFor(int trackId) => _smoothed[trackId] ?? 0.0;

  /// 清理已消失目标，避免长时间运行导致内存增长。
  void cleanStaleTracks(Set<int> activeTrackIds) {
    final stale = _smoothed.keys.where((id) => !activeTrackIds.contains(id)).toList();
    for (final id in stale) {
      _smoothed.remove(id);
      _lastFrame.remove(id);
    }
  }

  void reset() {
    _smoothed.clear();
    _lastFrame.clear();
  }
}
