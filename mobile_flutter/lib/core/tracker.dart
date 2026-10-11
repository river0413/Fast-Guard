/// 轻量航迹稳定器 —— 取代 PC 端的 TWS/ByteTrack，在端上给检测框分配稳定 ID。
///
/// 端上没有 ByteTrack（需要外部依赖），这里用贪心的
/// "IoU + 质心距离" 关联即可满足 TTC 计算对稳定轨迹的要求：
/// 同一个目标在相邻帧之间必须拿到同一个 ID，宽度历史才有意义。
library;

import 'dart:math' as math;

/// 单个检测框（像素坐标）。
class Detection {
  const Detection({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.score,
    required this.classId,
    required this.className,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double score;
  final int classId;
  final String className;

  double get width => x2 - x1;
  double get height => y2 - y1;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
  double get area => width * height;

  /// 相对于整帧的面积占比（TTC 计算需要）。
  double areaRatio(int frameWidth, int frameHeight) {
    final frameArea = frameWidth * frameHeight;
    return frameArea > 0 ? area / frameArea : 0.0;
  }

  double iou(Detection other) {
    final left = x1 > other.x1 ? x1 : other.x1;
    final top = y1 > other.y1 ? y1 : other.y1;
    final right = x2 < other.x2 ? x2 : other.x2;
    final bottom = y2 < other.y2 ? y2 : other.y2;
    final interWidth = right - left;
    final interHeight = bottom - top;
    if (interWidth <= 0 || interHeight <= 0) {
      return 0.0;
    }
    final intersection = interWidth * interHeight;
    final union = area + other.area - intersection;
    return union > 0 ? intersection / union : 0.0;
  }

  Detection copyWith({required int classId, required String className}) => Detection(
        x1: x1,
        y1: y1,
        x2: x2,
        y2: y2,
        score: score,
        classId: classId,
        className: className,
      );
}

/// 带稳定 ID 的航迹。
class Track {
  Track({
    required this.id,
    required this.detection,
    required this.hits,
    required this.lastSeenFrame,
  });

  final int id;
  Detection detection;
  int hits;
  int lastSeenFrame;

  /// 丢失的连续帧数（超过阈值即删除）。
  int misses = 0;
}

/// 贪心关联的简易跟踪器（IoU 优先，其次质心距离）。
class SimpleTracker {
  SimpleTracker({
    this.iouThreshold = 0.25,
    this.maxCenterDistanceRatio = 0.12,
    this.maxMisses = 15,
    this.minHits = 2,
  });

  final double iouThreshold;

  /// 质心距离上限（相对画面对角线），避免把远处目标错配到近处目标。
  final double maxCenterDistanceRatio;
  final int maxMisses;

  /// 连续命中该次数后才对外输出，抑制单帧误检。
  final int minHits;

  final List<Track> _tracks = [];
  int _nextId = 1;
  int _frameIndex = 0;

  List<Track> get tracks => List.unmodifiable(_tracks);

  /// 用当前帧的检测结果更新航迹，返回确认过的航迹（已排除未达 minHits 的）。
  List<Track> update(List<Detection> detections, int frameWidth, int frameHeight) {
    _frameIndex += 1;
    final frameDiagonal = math.sqrt(
      (frameWidth * frameWidth + frameHeight * frameHeight).toDouble(),
    );
    final maxDistance = frameDiagonal == 0 ? 1.0 : frameDiagonal * maxCenterDistanceRatio;

    final unmatched = List<Detection>.from(detections);
    // 先按 IoU 做贪心匹配
    for (final track in _tracks) {
      var bestIndex = -1;
      var bestIou = iouThreshold;
      for (var index = 0; index < unmatched.length; index++) {
        if (unmatched[index].classId != track.detection.classId) {
          continue;
        }
        final score = track.detection.iou(unmatched[index]);
        if (score > bestIou) {
          bestIou = score;
          bestIndex = index;
        }
      }
      if (bestIndex >= 0) {
        _applyMatch(track, unmatched.removeAt(bestIndex));
      }
    }

    // 再用质心距离补救（目标快速移动时 IoU 可能为 0）
    for (final track in _tracks.where((t) => t.lastSeenFrame != _frameIndex)) {
      var bestIndex = -1;
      var bestDistance = maxDistance;
      for (var index = 0; index < unmatched.length; index++) {
        if (unmatched[index].classId != track.detection.classId) {
          continue;
        }
        final dx = unmatched[index].centerX - track.detection.centerX;
        final dy = unmatched[index].centerY - track.detection.centerY;
        final distance = math.sqrt(dx * dx + dy * dy);
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      }
      if (bestIndex >= 0) {
        _applyMatch(track, unmatched.removeAt(bestIndex));
      }
    }

    // 剩余检测开新航迹
    for (final detection in unmatched) {
      _tracks.add(Track(
        id: _nextId++,
        detection: detection,
        hits: 1,
        lastSeenFrame: _frameIndex,
      ));
    }

    // 未匹配上的航迹计入 misses，超限删除
    _tracks.removeWhere((track) {
      if (track.lastSeenFrame == _frameIndex) {
        return false;
      }
      track.misses += 1;
      return track.misses > maxMisses;
    });

    return _tracks.where((track) => track.hits >= minHits).toList();
  }

  void _applyMatch(Track track, Detection detection) {
    track.detection = detection;
    track.hits += 1;
    track.misses = 0;
    track.lastSeenFrame = _frameIndex;
  }

  void reset() {
    _tracks.clear();
    _nextId = 1;
    _frameIndex = 0;
  }

  /// 主动推进一次"未命中"计数（没有新检测时用），用于清理长期不见的航迹。
  void pruneStale() => update(const <Detection>[], 1, 1);

  Set<int> get activeIds => _tracks.map((track) => track.id).toSet();
}
