/// TTC（碰撞时间）计算器 —— [core/calculator.py](../../../core/calculator.py) 的 Dart 移植。
///
/// 保持与 Python 实现一致的判定逻辑：用目标框宽度的增长率估算 TTC，并结合
/// 面积阈值、行驶通道（安全走廊）、背景流过滤、静态目标识别，输出 0/1/2 风险等级。
library;

import 'dart:collection';

/// 单帧的 TTC 计算结果。
class TtcResult {
  const TtcResult({
    required this.ttc,
    required this.vx,
    required this.vy,
    required this.dwDt,
    required this.redAllowed,
    required this.vw,
    required this.isStatic,
    required this.riskLevel,
    required this.inPath,
  });

  /// 平滑后的 TTC（秒）；等于 [TtcCalculator.safeTtc] 表示无碰撞风险。
  final double ttc;
  final double vx;
  final double vy;
  final double dwDt;
  final bool redAllowed;
  final double vw;
  final bool isStatic;

  /// 0 = 安全，1 = 注意，2 = 危险。
  final int riskLevel;

  /// 目标是否位于画面中央的行驶通道内。
  final bool inPath;
}

class TtcCalculator {
  TtcCalculator({
    required double fps,
    this.widthHistoryLen = 10,
    this.ttcHistoryLen = 5,
    this.safeTtc = 99.0,
  }) : fps = (fps > 0) ? fps : 30.0;

  final double fps;
  final int widthHistoryLen;
  final int ttcHistoryLen;
  final double safeTtc;

  final Map<int, Queue<double>> _widthHistory = {};
  final Map<int, Queue<double>> _xHistory = {};
  final Map<int, Queue<double>> _yHistory = {};
  final Map<int, Queue<double>> _ttcHistory = {};
  final Map<int, double> _widthEma = {};
  final Map<int, int> _lastFrameIndex = {};

  static void _push(Queue<double> queue, double value, int maxLen) {
    queue.addLast(value);
    while (queue.length > maxLen) {
      queue.removeFirst();
    }
  }

  static double _range(List<double> values) {
    var lo = values.first;
    var hi = values.first;
    for (final value in values) {
      if (value < lo) lo = value;
      if (value > hi) hi = value;
    }
    return hi - lo;
  }

  TtcResult update({
    required int trackId,
    required double width,
    required double centerX,
    required double centerY,
    required double bottomY,
    required double frameW,
    required double frameH,
    required double areaRatio,
    int frameIndex = 0,
    int maxFrameGap = 3,
    double globalVx = 0.0,
    double globalVy = 0.0,
    double minAreaRatio = 0.005,
    bool useEma = false,
    double emaAlpha = 0.3,
    double? distance,
    double vSelfMps = 0.0,
    double tReaction = 1.2,
    double dSafe = 2.0,
  }) {
    final widths = _widthHistory.putIfAbsent(trackId, () => Queue<double>());
    final xs = _xHistory.putIfAbsent(trackId, () => Queue<double>());
    final ys = _yHistory.putIfAbsent(trackId, () => Queue<double>());
    final ttcHist = _ttcHistory.putIfAbsent(trackId, () => Queue<double>());
    _widthEma.putIfAbsent(trackId, () => width);

    // 中断容忍：目标若超过 maxFrameGap 帧没被检测到，历史采样点之间就不再是等间隔，
    // 继续用 (wNow - wPrev) / (5/fps) 会把时间基算错（TTC 偏大或偏小）。
    // 因此这里直接清空该目标的历史，让它重新累积。
    final lastFrame = _lastFrameIndex[trackId];
    if (lastFrame != null && (frameIndex - lastFrame) > maxFrameGap) {
      widths.clear();
      xs.clear();
      ys.clear();
      ttcHist.clear();
      _widthEma[trackId] = width;
    }
    _lastFrameIndex[trackId] = frameIndex;

    double widthForCalc;
    if (useEma) {
      final previous = _widthEma[trackId]!;
      widthForCalc = emaAlpha * width + (1 - emaAlpha) * previous;
      _widthEma[trackId] = widthForCalc;
    } else {
      widthForCalc = width;
      _widthEma[trackId] = widthForCalc;
    }

    _push(widths, widthForCalc, widthHistoryLen);
    _push(xs, centerX, widthHistoryLen);
    _push(ys, centerY, widthHistoryLen);

    // 面积阈值：过滤过小的目标（原实现不再使用像素触底触发线）
    final redAllowed = areaRatio >= minAreaRatio;
    // 横向安全走廊：只看画面中央 35%–65%，过滤路侧目标
    final inPath = centerX >= frameW * 0.35 && centerX <= frameW * 0.65;

    var ttc = safeTtc;
    var dwDt = 0.0;

    // 宽度增长率 → TTC（需要至少 6 帧历史）
    if (widths.length >= 6) {
      final wNow = widths.last;
      final wPrev = widths.elementAt(widths.length - 6);
      if (wNow <= wPrev) {
        ttc = safeTtc;
      } else {
        dwDt = (wNow - wPrev) / (5.0 / fps);
        if (dwDt <= 0) {
          ttc = safeTtc;
        } else {
          ttc = wNow / dwDt;
          if (ttc <= 0) {
            ttc = safeTtc;
          }
        }
      }
    }

    // 外部距离兜底：仅当目标确实在靠近相机（vy < 0）时用它收紧 TTC
    if (distance != null && xs.length >= 2) {
      final vyWorld = (ys.last - ys.elementAt(ys.length - 2)) * fps - globalVy;
      if (vyWorld < -1e-3) {
        final ttcByDistance = (distance / vyWorld).abs();
        if (ttcByDistance > 0 && ttcByDistance < ttc) {
          ttc = ttcByDistance;
        }
      }
    }

    var vx = 0.0;
    var vy = 0.0;
    var vw = 0.0;
    if (xs.length >= 2) {
      vx = (xs.last - xs.elementAt(xs.length - 2)) * fps - globalVx;
      vy = (ys.last - ys.elementAt(ys.length - 2)) * fps - globalVy;
      vw = (widths.last - widths.elementAt(widths.length - 2)) * fps;
    }

    // 静态目标：近 10 帧内位置与宽度几乎不动
    var isStatic = false;
    if (xs.length >= 10) {
      final recentX = xs.toList().sublist(xs.length - 10);
      final recentY = ys.toList().sublist(ys.length - 10);
      final recentW = widths.toList().sublist(widths.length - 10);
      if (_range(recentX) <= 2.0 && _range(recentY) <= 2.0 && _range(recentW) <= 2.0) {
        isStatic = true;
      }
    }

    _push(ttcHist, ttc < safeTtc ? ttc : safeTtc, ttcHistoryLen);
    var sum = 0.0;
    for (final value in ttcHist) {
      sum += value;
    }
    final avgTtc = sum / ttcHist.length;

    // === 风险分级 ===
    var riskLevel = 0;
    var vRelEff = -vSelfMps;
    if (distance != null && xs.length >= 2) {
      vRelEff = (ys.last - ys.elementAt(ys.length - 2)) * fps - globalVy - vSelfMps;
    }
    // 动态安全距离 SDT = V_self * t_reaction + d_safe
    final sdtDyn = (vSelfMps > 0 ? vSelfMps : 0.0) * tReaction + dSafe;
    const ttcThreshold = 2.0;

    // 背景流过滤：横向速度与"偏离画面中心"同向、且相对速度近 0 → 判为背景
    var backgroundFlow = false;
    if (xs.length >= 2) {
      final signFlow = (centerX - frameW * 0.5) * vx;
      if (signFlow > 0 && vRelEff.abs() < 0.5) {
        backgroundFlow = true;
      }
    }

    if (inPath && redAllowed && !backgroundFlow) {
      final closeEnough = distance != null && distance < sdtDyn;
      if (closeEnough && avgTtc < ttcThreshold) {
        riskLevel = 2;
      } else if (avgTtc < ttcThreshold) {
        riskLevel = 1;
      }
    }

    // 快速横移且不在行驶通道内 → 强制降级（避免路侧横穿误报）
    if (vx.abs() > 6.0 && !inPath) {
      riskLevel = 0;
    }

    return TtcResult(
      ttc: avgTtc < safeTtc ? avgTtc : safeTtc,
      vx: vx,
      vy: vy,
      dwDt: dwDt,
      redAllowed: redAllowed,
      vw: vw,
      isStatic: isStatic,
      riskLevel: riskLevel,
      inPath: inPath,
    );
  }

  /// 清理已消失目标，避免长时间运行导致内存增长。
  void cleanStaleTracks(Set<int> activeTrackIds) {
    final stale = _widthHistory.keys.where((id) => !activeTrackIds.contains(id)).toList();
    for (final id in stale) {
      _widthHistory.remove(id);
      _widthEma.remove(id);
      _ttcHistory.remove(id);
      _xHistory.remove(id);
      _yHistory.remove(id);
      _lastFrameIndex.remove(id);
    }
  }
}
