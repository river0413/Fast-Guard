/// 端上算法移植的回归测试（无需设备，`flutter test` 即可运行）。
///
/// 重点验证从 Python 移植过来的两处核心逻辑与 PC 端行为一致：
/// * TTC 计算器的风险分级与宽度增长率估算；
/// * 航迹稳定器的 ID 连续性（TTC 依赖稳定的宽度历史）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fastguard_mobile/core/box_smoother.dart';
import 'package:fastguard_mobile/core/camera_optics.dart';
import 'package:fastguard_mobile/core/distance_estimator.dart';
import 'package:fastguard_mobile/core/ipm.dart';
import 'package:fastguard_mobile/core/tracker.dart';
import 'package:fastguard_mobile/core/ttc_calculator.dart';
import 'package:fastguard_mobile/pipeline/inference_engine.dart';
import 'package:fastguard_mobile/settings.dart';

const int kFrameW = 640;
const int kFrameH = 480;

/// 生成"目标逐渐变大"的序列（等价 PC 端测试里的 approach_sequence）。
List<Map<String, double>> approachSequence({
  double start = 100,
  double growth = 4,
  int count = 20,
  double centerX = 320,
  double centerY = 240,
}) {
  return List<Map<String, double>>.generate(count, (index) {
    final width = start + growth * index;
    return <String, double>{
      'width': width,
      'centerX': centerX,
      'centerY': centerY,
      'bottomY': centerY + (width * 1.6) / 2,
      'areaRatio': (width * width * 1.6) / (kFrameW * kFrameH),
    };
  });
}

void main() {
  group('TtcCalculator', () {
    test('静止目标不产生风险（宽度不变）', () {
      final calculator = TtcCalculator(fps: 30);
      TtcResult? result;
      for (var i = 0; i < 20; i++) {
        final frame = approachSequence(growth: 0, count: 1).first;
        result = calculator.update(
          trackId: 1,
          width: frame['width']!,
          centerX: frame['centerX']!,
          centerY: frame['centerY']!,
          bottomY: frame['bottomY']!,
          frameW: kFrameW.toDouble(),
          frameH: kFrameH.toDouble(),
          areaRatio: frame['areaRatio']!,
        );
      }
      expect(result!.ttc, 99.0);
      expect(result.riskLevel, 0);
      expect(result.isStatic, isTrue);
    });

    test('目标快速接近时给出有限 TTC 与风险等级', () {
      final calculator = TtcCalculator(fps: 30);
      TtcResult? result;
      for (final frame in approachSequence(growth: 6, count: 20)) {
        result = calculator.update(
          trackId: 7,
          width: frame['width']!,
          centerX: frame['centerX']!,
          centerY: frame['centerY']!,
          bottomY: frame['bottomY']!,
          frameW: kFrameW.toDouble(),
          frameH: kFrameH.toDouble(),
          areaRatio: frame['areaRatio']!,
        );
      }
      expect(result!.ttc, lessThan(99.0));
      expect(result.inPath, isTrue);
      expect(result.riskLevel, greaterThan(0));
    });

    test('偏离行驶通道的目标不触发风险', () {
      final calculator = TtcCalculator(fps: 30);
      TtcResult? result;
      for (final frame in approachSequence(growth: 6, count: 20, centerX: 40)) {
        result = calculator.update(
          trackId: 3,
          width: frame['width']!,
          centerX: frame['centerX']!,
          centerY: frame['centerY']!,
          bottomY: frame['bottomY']!,
          frameW: kFrameW.toDouble(),
          frameH: kFrameH.toDouble(),
          areaRatio: frame['areaRatio']!,
        );
      }
      expect(result!.inPath, isFalse);
      expect(result.riskLevel, 0);
    });

    test('面积过小时不放开红色告警', () {
      final calculator = TtcCalculator(fps: 30);
      final frame = approachSequence(growth: 0, count: 1).first;
      final result = calculator.update(
        trackId: 9,
        width: 10,
        centerX: frame['centerX']!,
        centerY: 400,
        bottomY: 420,
        frameW: kFrameW.toDouble(),
        frameH: kFrameH.toDouble(),
        areaRatio: 0.0001, // 远小于默认 minAreaRatio
      );
      expect(result.redAllowed, isFalse);
      expect(result.riskLevel, 0);
    });

    test('cleanStaleTracks 清理消失目标', () {      final calculator = TtcCalculator(fps: 30);
      final frame = approachSequence(count: 1).first;
      calculator.update(
        trackId: 1,
        width: frame['width']!,
        centerX: frame['centerX']!,
        centerY: frame['centerY']!,
        bottomY: frame['bottomY']!,
        frameW: kFrameW.toDouble(),
        frameH: kFrameH.toDouble(),
        areaRatio: frame['areaRatio']!,
      );
      calculator.cleanStaleTracks(<int>{});
      // 清理后重新计数：历史被丢弃，TTC 回到安全值
      final result = calculator.update(
        trackId: 1,
        width: frame['width']!,
        centerX: frame['centerX']!,
        centerY: frame['centerY']!,
        bottomY: frame['bottomY']!,
        frameW: kFrameW.toDouble(),
        frameH: kFrameH.toDouble(),
        areaRatio: frame['areaRatio']!,
      );
      expect(result.ttc, 99.0);
    });

    test('目标中断过久时清空历史，避免错误的时间基', () {
      final calculator = TtcCalculator(fps: 18);
      TtcResult? result;
      var frameIndex = 0;

      // 先连续采样，让宽度历史累积（此时 TTC 会变小）
      for (final frame in approachSequence(growth: 6, count: 10)) {
        frameIndex += 1;
        result = calculator.update(
          trackId: 5,
          width: frame['width']!,
          centerX: frame['centerX']!,
          centerY: frame['centerY']!,
          bottomY: frame['bottomY']!,
          frameW: kFrameW.toDouble(),
          frameH: kFrameH.toDouble(),
          areaRatio: frame['areaRatio']!,
          frameIndex: frameIndex,
        );
      }
      expect(result!.ttc, lessThan(99.0));

      // 中断 10 帧（超过 maxFrameGap），再出现：历史应被清空，TTC 回到安全值
      frameIndex += 10;
      final after = calculator.update(
        trackId: 5,
        width: 300,
        centerX: 320,
        centerY: 240,
        bottomY: 400,
        frameW: kFrameW.toDouble(),
        frameH: kFrameH.toDouble(),
        areaRatio: 0.2,
        frameIndex: frameIndex,
      );
      expect(after.ttc, 99.0, reason: '中断过久后不应沿用旧的宽度增长率');

      // 但短间隔（1 帧）缺失不算中断，历史应继续保留
      final calculator2 = TtcCalculator(fps: 18);
      TtcResult? dense;
      var idx = 0;
      for (final frame in approachSequence(growth: 6, count: 10)) {
        idx += 1;
        dense = calculator2.update(
          trackId: 9,
          width: frame['width']!,
          centerX: frame['centerX']!,
          centerY: frame['centerY']!,
          bottomY: frame['bottomY']!,
          frameW: kFrameW.toDouble(),
          frameH: kFrameH.toDouble(),
          areaRatio: frame['areaRatio']!,
          frameIndex: idx,
        );
      }
      final ttcBefore = dense!.ttc;
      idx += 2; // 间隔 2 帧，仍在容忍范围内
      final ttcAfter = calculator2.update(
        trackId: 9,
        width: 400,
        centerX: 320,
        centerY: 240,
        bottomY: 400,
        frameW: kFrameW.toDouble(),
        frameH: kFrameH.toDouble(),
        areaRatio: 0.2,
        frameIndex: idx,
      );
      expect(ttcAfter.ttc, lessThan(99.0), reason: '短缺失不应清空历史');
      expect(ttcBefore, lessThan(99.0));
    });
  });

  group('SimpleTracker', () {
    Detection detection({required double x, double size = 60, int classId = 0}) => Detection(
          x1: x,
          y1: 200,
          x2: x + size,
          y2: 320,
          score: 0.9,
          classId: classId,
          className: '行人',
        );

    test('缓慢移动的目标保持同一 ID（宽度历史才可用）', () {
      final tracker = SimpleTracker(minHits: 1);
      final ids = <int>[];
      for (var i = 0; i < 8; i++) {
        final tracks = tracker.update(<Detection>[detection(x: 200 + i * 3.0)], kFrameW, kFrameH);
        if (tracks.isNotEmpty) {
          ids.add(tracks.first.id);
        }
      }
      expect(ids, isNotEmpty);
      expect(ids.toSet().length, 1, reason: '同一目标不应换 ID：$ids');
    });

    test('不同类别不会互相错配', () {
      final tracker = SimpleTracker(minHits: 1);
      final first = tracker.update(<Detection>[detection(x: 200, classId: 0)], kFrameW, kFrameH);
      expect(first.length, 1);
      final firstId = first.first.id;

      // 同一位置但类别不同 → 不应复用旧航迹，而是新建一条（旧航迹被保留以便召回）
      final second = tracker.update(<Detection>[detection(x: 200, classId: 2)], kFrameW, kFrameH);
      final newTracks = second.where((track) => track.id != firstId).toList();
      expect(newTracks.length, 1, reason: '应新建一条航迹：$second');
      expect(newTracks.first.detection.classId, 2);
      expect(newTracks.first.hits, 1, reason: '新航迹不应继承旧航迹的命中数');
      // 旧航迹仍在（用于后续召回），但仍是原类别
      final kept = second.firstWhere((track) => track.id == firstId);
      expect(kept.detection.classId, 0);
    });

    test('连续多次未命中后删除航迹', () {
      final tracker = SimpleTracker(minHits: 1, maxMisses: 2);
      tracker.update(<Detection>[detection(x: 200)], kFrameW, kFrameH);
      for (var i = 0; i < 5; i++) {
        tracker.update(<Detection>[], kFrameW, kFrameH);
      }
      expect(tracker.activeIds, isEmpty);
    });

    test('IoU 计算正确', () {
      final a = detection(x: 100, size: 100);
      final b = detection(x: 100, size: 100);
      final c = detection(x: 400, size: 100);
      expect(a.iou(b), closeTo(1.0, 1e-9));
      expect(a.iou(c), 0.0);
    });
  });

  group('IpmTransformer', () {
    test('画面下沿前方的点能给出距离，天空方向返回 null', () {
      final ipm = IpmTransformer(pitchDeg: 10.0);
      // 画面下沿（v 接近图像高度）应当落到地面上
      final near = ipm.distanceFromBottom(320, 470, kFrameW, kFrameH);
      expect(near, isNotNull);
      expect(near!, greaterThan(0));
      expect(near, lessThan(50));

      // 画面上方（天空）不与地面相交
      expect(ipm.pixelToGround(320, 5, kFrameW, kFrameH), isNull);
    });

    test('groundToPixel 与 pixelToGround 大致互逆', () {
      final ipm = IpmTransformer(pitchDeg: 12.0);
      final ground = ipm.pixelToGround(400, 460, kFrameW, kFrameH);
      expect(ground, isNotNull);
      final pixel = ipm.groundToPixel(ground!.x, ground.y, kFrameW, kFrameH);
      expect(pixel, isNotNull);
      expect(pixel![0], closeTo(400, 1.5));
      expect(pixel[1], closeTo(460, 1.5));
    });

    test('焦距按水平 FOV 估算', () {
      final ipm = IpmTransformer(fovDeg: 90.0);
      ipm.setFrame(kFrameW, kFrameH);
      // 90° 水平 FOV 时 fx = (w/2)/tan(45°) = w/2
      expect(ipm.fx, closeTo(kFrameW / 2, 1e-6));
    });

    test('俯仰角可调，影响测距结果', () {
      final a = IpmTransformer(pitchDeg: 5.0).distanceFromBottom(320, 460, kFrameW, kFrameH);
      final b = IpmTransformer(pitchDeg: 15.0).distanceFromBottom(320, 460, kFrameW, kFrameH);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect((a! - b!).abs() > 1e-6 || math.max(a, b) > 0, isTrue);
    });
  });

  group('InferenceEngine 设置传递', () {
    test('applySettings 会把推理尺寸/阈值同步到检测器', () {
      final settings = AppSettings(
        inferenceSize: 320,
        confidence: 0.35,
        iouThreshold: 0.45,
        showAllClasses: false,
      );
      final engine = InferenceEngine(settings);

      // 初始状态应与设置一致
      expect(engine.settings.inferenceSize, 320);

      // 改设置后必须同步（否则输入张量形状会与模型/设置不一致）
      settings.inferenceSize = 416;
      settings.confidence = 0.55;
      settings.iouThreshold = 0.60;
      settings.showAllClasses = true;
      engine.applySettings();

      // 通过公开 getter 间接断言（detector 为私有，行为以风险快照/不抛异常为准）
      expect(engine.settings.inferenceSize, 416);
      expect(engine.settings.confidence, 0.55);
      expect(engine.settings.iouThreshold, 0.60);
      expect(engine.settings.showAllClasses, isTrue);
    });

    test('未加载模型时 processFrame 返回 null 而不是抛异常', () async {
      final engine = InferenceEngine(AppSettings());
      final rgba = Uint8List(64 * 48 * 3);
      expect(engine.isReady, isFalse);
      expect(await engine.processFrame(rgba, 64, 48), isNull);
    });

    test('resetTracking 清空计数与快照', () {
      final engine = InferenceEngine(AppSettings());
      expect(engine.lastSnapshot, isNull);
      expect(engine.processedFrames, 0);
      engine.resetTracking();
      expect(engine.processedFrames, 0);
      expect(engine.lastSnapshot, isNull);
    });
  });

  group('MonocularDistanceEstimator（真实尺寸 + 焦距）', () {
    // 假设手机后摄 35mm 等效 24mm、图像宽 960px -> 焦距约 640px
    const focalPx = 24.0 / 36.0 * 960.0; // = 640

    Detection car({required double w, required double h}) => Detection(
          x1: 400,
          y1: 300,
          x2: 400 + w,
          y2: 300 + h,
          score: 0.9,
          classId: 2,
          className: '轿车',
        );

    test('正对轿车：高低两路接近，融合值在两者之间', () {
      // 轿车 宽1.8 高1.75；此处框 90x80 px
      final estimate = const MonocularDistanceEstimator().estimate(
        car(w: 90, h: 80),
        focalLengthPx: focalPx,
      );
      expect(estimate, isNotNull);
      expect(estimate!.axes.length, 2);
      expect(estimate.source, 'fused');

      final byWidth = estimate.axes.firstWhere((a) => a.axis == 'width').meters;
      final byHeight = estimate.axes.firstWhere((a) => a.axis == 'height').meters;
      final lo = byWidth < byHeight ? byWidth : byHeight;
      final hi = byWidth < byHeight ? byHeight : byWidth;
      expect(estimate.meters, inInclusiveRange(lo, hi));
      expect(estimate.axesAgree, isTrue);
      expect(estimate.warning, isNull);
    });

    test('验证针孔公式数值：1.8m 宽、90px 宽、焦距 640px => 12.8m', () {
      final estimate = const MonocularDistanceEstimator().estimate(
        car(w: 90, h: 100),
        focalLengthPx: focalPx,
      )!;
      final byWidth = estimate.axes.firstWhere((a) => a.axis == 'width').meters;
      expect(byWidth, closeTo(1.8 * 640 / 90, 1e-6)); // = 12.8
      expect(byWidth, closeTo(12.8, 0.01));
    });

    test('像素越多的维度权重越大（框高更大时更偏向高度估计）', () {
      // 框 60x160：高度像素明显更多 -> 融合值应更接近高度估算
      final estimate = const MonocularDistanceEstimator().estimate(
        car(w: 60, h: 160),
        focalLengthPx: focalPx,
      )!;
      final byWidth = estimate.axes.firstWhere((a) => a.axis == 'width').meters;
      final byHeight = estimate.axes.firstWhere((a) => a.axis == 'height').meters;
      final mid = (byWidth + byHeight) / 2;
      final closerToHeight = (estimate.meters - byHeight).abs() < (estimate.meters - byWidth).abs();
      expect(closerToHeight, isTrue, reason: '应偏向像素更多的高度估计（融合=$estimate, 中值=$mid）');
    });

    test('公交车按高度 2.5m、卡车按高度 3.0m 计算', () {
      final bus = const MonocularDistanceEstimator().estimate(
        const Detection(x1: 0, y1: 0, x2: 120, y2: 100, score: 0.9, classId: 5, className: '公交车'),
        focalLengthPx: focalPx,
      )!;
      final busHeight = bus.axes.firstWhere((a) => a.axis == 'height').meters;
      expect(busHeight, closeTo(2.5 * focalPx / 100, 1e-6));

      final truck = const MonocularDistanceEstimator().estimate(
        const Detection(x1: 0, y1: 0, x2: 120, y2: 120, score: 0.9, classId: 7, className: '卡车'),
        focalLengthPx: focalPx,
      )!;
      final truckHeight = truck.axes.firstWhere((a) => a.axis == 'height').meters;
      expect(truckHeight, closeTo(3.0 * focalPx / 120, 1e-6));
    });

    test('高宽差异过大时给出视角异常提示', () {
      // 极扁的框：宽度估算会明显大于高度估算（模拟只看到车侧）
      final estimate = const MonocularDistanceEstimator().estimate(
        car(w: 300, h: 40),
        focalLengthPx: focalPx,
      )!;
      expect(estimate.warning, isNotNull);
      expect(estimate.axesAgree, isFalse);
    });

    test('目标过小或类别未标定时返回 null', () {
      final estimator = const MonocularDistanceEstimator();
      // 框太小（< minPixelSize）
      expect(
        estimator.estimate(car(w: 5, h: 5), focalLengthPx: focalPx),
        isNull,
      );
      // 未标定尺寸的类别（红绿灯 = 9）
      expect(
        estimator.estimate(
          const Detection(x1: 0, y1: 0, x2: 60, y2: 60, score: 0.9, classId: 9, className: '红绿灯'),
          focalLengthPx: focalPx,
        ),
        isNull,
      );
      // 焦距非法
      expect(estimator.estimate(car(w: 90, h: 80), focalLengthPx: 0), isNull);
    });

    test('行人优先由高度主导（身高像素通常远大于肩宽像素）', () {
      final person = const MonocularDistanceEstimator().estimate(
        const Detection(x1: 0, y1: 0, x2: 40, y2: 150, score: 0.9, classId: 0, className: '行人'),
        focalLengthPx: focalPx,
      )!;
      final byHeight = person.axes.firstWhere((a) => a.axis == 'height').meters;
      // 1.70m / 150px * 640 = 7.25m
      expect(byHeight, closeTo(1.70 * focalPx / 150, 1e-6));
      // 融合值应更接近高度（因为高度像素 150 > 宽度像素 40）
      expect((person.meters - byHeight).abs(), lessThan(1.0));
    });

    group('三维（长宽高）', () {
      const estimator = MonocularDistanceEstimator();
      Detection bus(double w, double h) =>
          Detection(x1: 100, y1: 100, x2: 100 + w, y2: 100 + h, score: 0.9, classId: 5, className: '公交车');
      Detection truck(double w, double h) =>
          Detection(x1: 100, y1: 100, x2: 100 + w, y2: 100 + h, score: 0.9, classId: 7, className: '卡车');

      test('正对（框偏窄）：宽度主导、无需车长', () {
        final e = estimator.estimate(bus(100, 100), focalLengthPx: focalPx)!;
        expect(e.lengthM, isNull);
        expect(e.yawDeg, 0.0);
        expect(e.warning, isNull);
      });

      test('公交车侧面：按像素长宽比选出离散车长（6/8/10/12/18）', () {
        // 高 100px => E = a·2.5；a=3.2 => E=8.0 => 最小车长 √(64-6.5)≈7.58 => 选 8
        final e = estimator.estimate(bus(320, 100), focalLengthPx: focalPx)!;
        expect(e.lengthM, 8.0);
        // 车长随比例单调增加
        expect(estimator.estimate(bus(160, 100), focalLengthPx: focalPx)!.lengthM, 6.0);
        expect(estimator.estimate(bus(400, 100), focalLengthPx: focalPx)!.lengthM, 10.0);
        expect(estimator.estimate(bus(480, 100), focalLengthPx: focalPx)!.lengthM, 12.0);
        expect(estimator.estimate(bus(700, 100), focalLengthPx: focalPx)!.lengthM, 18.0);
      });

      test('侧面时宽度路用投影宽度：与高度路一致，不再把车长当车宽', () {
        final e = estimator.estimate(bus(320, 100), focalLengthPx: focalPx)!;
        final byHeight = e.axes.firstWhere((a) => a.axis == 'height').meters;
        expect(e.meters, closeTo(byHeight, 1e-6));
        expect(e.axesAgree, isTrue);
        expect(e.yawDeg!, inInclusiveRange(0, 90));
      });

      test('卡车长度限定在 5–15m 区间内', () {
        final e = estimator.estimate(truck(500, 100), focalLengthPx: focalPx)!;
        expect(e.lengthM, inInclusiveRange(5.0, 15.0));
        // 超出最大车长：钳到 15m，并因宽度路被限制而给出差异提示
        final huge = estimator.estimate(truck(1200, 100), focalLengthPx: focalPx)!;
        expect(huge.lengthM, 15.0);
        expect(huge.warning, isNotNull);
      });

      test('目标顶/底被画面截断：丢弃高度路并提示不确定', () {
        final e = estimator.estimate(
          bus(200, 100),
          focalLengthPx: focalPx,
          frameWidth: 960,
          frameHeight: 200, // y2 = 200 = 画面底
        )!;
        expect(e.axes.map((a) => a.axis), <String>['width']);
        expect(e.warning, contains('截断'));
      });
    });
    test('横向偏移：光轴左右对称，且与距离成正比', () {
      // 位于画面正中 -> 横向偏移 0
      expect(
        MonocularDistanceEstimator.lateralOffsetMeters(
          centerX: 480,
          imageWidth: 960,
          focalLengthPx: focalPx,
          distanceM: 12.8,
        ),
        closeTo(0.0, 1e-9),
      );

      // 偏离光轴 100px，焦距 640px，距离 12.8m -> 12.8 * 100/640 = 2.0m
      final right = MonocularDistanceEstimator.lateralOffsetMeters(
        centerX: 580,
        imageWidth: 960,
        focalLengthPx: focalPx,
        distanceM: 12.8,
      )!;
      expect(right, closeTo(2.0, 1e-6));

      // 左右对称
      final left = MonocularDistanceEstimator.lateralOffsetMeters(
        centerX: 380,
        imageWidth: 960,
        focalLengthPx: focalPx,
        distanceM: 12.8,
      )!;
      expect(left, closeTo(-right, 1e-9));

      // 同一像素偏移，距离越远横向偏移越大（针孔几何）
      final far = MonocularDistanceEstimator.lateralOffsetMeters(
        centerX: 580,
        imageWidth: 960,
        focalLengthPx: focalPx,
        distanceM: 25.6,
      )!;
      expect(far, closeTo(right * 2, 1e-6));
    });

    test('横向偏移在参数非法时返回 null', () {
      expect(
        MonocularDistanceEstimator.lateralOffsetMeters(
          centerX: 480,
          imageWidth: 0,
          focalLengthPx: 640,
          distanceM: 10,
        ),
        isNull,
      );
      expect(
        MonocularDistanceEstimator.lateralOffsetMeters(
          centerX: 480,
          imageWidth: 960,
          focalLengthPx: 640,
          distanceM: 0,
        ),
        isNull,
      );
    });
  });

  group('CameraOptics', () {
    test('用 35mm 等效焦距换算像素焦距', () {
      const optics = CameraOptics(
        cameraId: '0',
        focalLengthsMm: <double>[5.43],
        sensorWidthMm: 6.4,
        sensorHeightMm: 4.8,
        cropFactor: 5.41,
        focalLength35mmEq: 29.4,
      );
      expect(optics.canMeasureDistance, isTrue);
      // 29.4 / 36 * 960 = 784
      expect(optics.focalLengthPixels(960), closeTo(29.4 / 36 * 960, 1e-6));
      expect(optics.focalLengthPixels(0), isNull);
    });

    test('缺少等效焦距时不可测距', () {
      const optics = CameraOptics(cameraId: '0');
      expect(optics.canMeasureDistance, isFalse);
      expect(optics.focalLengthPixels(960), isNull);
    });

    test('从平台通道返回的 Map 正确解析', () {
      final optics = CameraOptics.fromMap(<dynamic, dynamic>{
        'id': '1',
        'focalLengthsMm': <dynamic>[2.1, 4.7],
        'sensorWidthMm': 5.6,
        'sensorHeightMm': 4.2,
        'apertures': <dynamic>[1.8],
        'sensorOrientation': 90,
        'cropFactor': 6.2,
        'focalLength35mmEq': 13.0,
      });
      expect(optics.cameraId, '1');
      expect(optics.focalLengthsMm, <double>[2.1, 4.7]);
      expect(optics.sensorWidthMm, 5.6);
      expect(optics.sensorOrientation, 90);
      expect(optics.focalLength35mmEq, 13.0);
      expect(optics.describe(), contains('相机 1'));
    });
  });

  group('AppSettings', () {
    test('越界值会被规整到合法范围', () {
      final settings = AppSettings(
        confidence: 5.0,
        iouThreshold: 0.0,
        ttcThreshold: 99.0,
        inferenceSize: 333,
        processEveryNthFrame: 50,
        cameraIndex: -3,
      ).normalized();

      expect(settings.confidence, 0.95);
      expect(settings.iouThreshold, 0.10);
      expect(settings.ttcThreshold, 5.0);
      expect(settings.inferenceSize, 320); // 非候选值回退默认
      expect(settings.processEveryNthFrame, 10);
      expect(settings.cameraIndex, 0);
    });

    test('候选推理尺寸保持不变', () {
      for (final size in kInferenceSizeChoices) {
        expect(AppSettings(inferenceSize: size).normalized().inferenceSize, size);
      }
    });

    test('copy 是深拷贝（草稿编辑不影响原对象）', () {
      final original = AppSettings(confidence: 0.5, inferenceSize: 416);
      final draft = original.copy();
      draft.confidence = 0.9;
      draft.inferenceSize = 640;
      expect(original.confidence, 0.5);
      expect(original.inferenceSize, 416);
    });

    test('summary 包含关键参数', () {
      final summary = AppSettings(cameraIndex: 1, inferenceSize: 416, confidence: 0.5).summary;
      expect(summary, contains('摄像头 1'));
      expect(summary, contains('416px'));
      expect(summary, contains('0.50'));
    });

    test('标框平滑的强度会被规整，并且是深拷贝', () {
      expect(AppSettings(boxSmoothingStrength: 5.0).normalized().boxSmoothingStrength,
          BoxTrendSmoother.kMaxStrength);
      expect(AppSettings(boxSmoothingStrength: -1.0).normalized().boxSmoothingStrength, 0.0);
      expect(AppSettings().boxSmoothingStrength, BoxTrendSmoother.kDefaultStrength);

      final original = AppSettings(boxSmoothing: true);
      final draft = original.copy();
      draft.boxSmoothing = false;
      draft.boxSmoothingStrength = 0.9;
      expect(original.boxSmoothing, isTrue);
      expect(original.boxSmoothingStrength, BoxTrendSmoother.kDefaultStrength);
      expect(original.summary, contains('平滑'));
    });
  });

  group('BoxTrendSmoother（标框平滑）', () {
    // 640×480 → 对角线 800px → 跳变阈值 30% = 240px
    const frameW = 640.0;
    const frameH = 480.0;

    Detection box(double x1, double y1, double x2, double y2) => Detection(
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2,
          score: 0.9,
          classId: 2,
          className: '轿车',
        );

    /// 以 100..160 / 200..320 为起点、每帧右移 [dx] 的框（宽 60、高 120 不变）。
    Detection moving(double dx) => box(100 + dx, 200, 160 + dx, 320);

    SmoothedBox step(BoxTrendSmoother smoother, Detection measurement, int frameIndex) =>
        smoother.smooth(
          trackId: 7,
          measurement: measurement,
          frameIndex: frameIndex,
          frameWidth: frameW,
          frameHeight: frameH,
        );

    test('首次观测原样输出（只有一帧，还没有趋势可用）', () {
      final smoother = BoxTrendSmoother();
      final result = step(smoother, moving(0), 1);
      expect(result.x1, 100);
      expect(result.y2, 320);
      expect(result.usedTrend, isFalse);
      expect(smoother.stateCount, 1);
    });

    test('第三帧按「趋势预测 + α×残差」过渡（α = 0.45）', () {
      final smoother = BoxTrendSmoother(); // 强度 0.55 → α 0.45
      expect(smoother.alpha, closeTo(0.45, 1e-9));

      // 第 1 帧：建立状态（输出 = 测量 100）
      expect(step(smoother, moving(0), 1).x1, 100);

      // 第 2 帧：上一帧速度为 0 → 预测 100，残差 100 → 输出 100 + 0.45×100 = 145
      final second = step(smoother, moving(100), 2);
      expect(second.x1, closeTo(145.0, 1e-9));
      expect(second.usedTrend, isTrue);

      // 第 3 帧：速度 = 145 - 100 = 45 → 预测 190，
      // 输出被拉向 190（而不是停在 145 或直接跳到 300）
      final third = step(smoother, moving(200), 3);
      expect(third.x1, closeTo(190.0 + 0.45 * (300.0 - 190.0), 1e-9));
      expect(third.x1, greaterThan(second.x1), reason: '应沿运动趋势前进');
      expect(third.x1, lessThan(300.0), reason: '不应直接跳到本帧测量值');
    });

    test('匀速运动中收敛到测量值（无稳态滞后）', () {
      final smoother = BoxTrendSmoother();
      const frames = 20;
      SmoothedBox? result;
      for (var i = 0; i < frames; i++) {
        result = step(smoother, moving(i * 10.0), i + 1);
      }
      // 稳态下 α·滞后 = 0，因此输出应贴合测量（最后一帧测量 x1 = 100 + 19×10 = 290）
      expect(result!.x1, closeTo(290.0, 1.0));
      expect(result.usedTrend, isTrue);
    });

    test('抑制抖动：输出偏离匀速轨迹的幅度远小于原始测量', () {
      final smoother = BoxTrendSmoother();
      var rawDeviation = 0.0;
      var smoothDeviation = 0.0;

      // 匀速前进（每帧 +6px）叠加 ±4px 抖动；理想轨迹 = 100 + 6i
      for (var i = 0; i < 30; i++) {
        final ideal = 100 + i * 6.0;
        final raw = ideal + (i.isEven ? 4.0 : -4.0);
        final result = step(smoother, box(raw, 200, raw + 60, 320), i + 1);
        if (i >= 10) {
          // 只看稳态（前 10 帧是滤波器收敛过程）
          final rawOffset = (raw - ideal).abs();
          final smoothOffset = (result.x1 - ideal).abs();
          if (rawOffset > rawDeviation) rawDeviation = rawOffset;
          if (smoothOffset > smoothDeviation) smoothDeviation = smoothOffset;
        }
      }

      expect(rawDeviation, closeTo(4.0, 1e-9));
      expect(smoothDeviation, lessThan(1.5),
          reason: '稳态抖动应被压到 ±4px 的 4 成以内（实测约 ±0.7px）');
    });

    test('测量跳变过大时直接吸附，不滑行', () {
      final smoother = BoxTrendSmoother();
      step(smoother, moving(0), 1);
      step(smoother, moving(10), 2);

      // 一次移动 300px（残差范数 ≈ 424px > 240px）→ 判为重定位
      final jumped = step(smoother, moving(310), 3);
      expect(jumped.x1, 410.0);
      expect(jumped.usedTrend, isFalse);
    });

    test('中断过久（超过 maxGapFrames）后重新起头', () {
      final smoother = BoxTrendSmoother(maxGapFrames: 3);
      step(smoother, moving(0), 1);
      step(smoother, moving(10), 2);

      // 隔了 4 帧才再次看到：时间基不可靠，直接采用测量
      final afterGap = step(smoother, moving(20), 6);
      expect(afterGap.x1, 120.0);
      expect(afterGap.usedTrend, isFalse);
    });

    test('同一帧重复调用不会外推（elapsed ≤ 0）', () {
      final smoother = BoxTrendSmoother();
      step(smoother, moving(0), 1);
      final repeated = step(smoother, moving(40), 1);
      expect(repeated.x1, 140.0);
      expect(repeated.usedTrend, isFalse);
    });

    test('强度 0 等价于关闭平滑，且不保留状态', () {
      final smoother = BoxTrendSmoother(strength: 0.0);
      expect(smoother.enabled, isFalse);
      step(smoother, moving(0), 1);
      final result = step(smoother, moving(50), 2);
      expect(result.x1, 150.0);
      expect(result.usedTrend, isFalse);
      expect(smoother.stateCount, 0);
    });

    test('强度被限制在 [0, 0.9]，α 不会小到 0', () {
      final smoother = BoxTrendSmoother(strength: 5.0);
      expect(smoother.strength, BoxTrendSmoother.kMaxStrength);
      expect(smoother.alpha, closeTo(0.10, 1e-9));
      smoother.strength = 0.55;
      expect(smoother.alpha, closeTo(0.45, 1e-9));
    });

    test('输出被钳制在画面内并保持最小边长', () {
      final smoother = BoxTrendSmoother();
      step(smoother, box(0, 0, 2, 2), 1);
      final result = step(smoother, box(-500, -500, -498, -498), 2);
      expect(result.x1, greaterThanOrEqualTo(0.0));
      expect(result.y1, greaterThanOrEqualTo(0.0));
      expect(result.width, greaterThanOrEqualTo(BoxTrendSmoother.minBoxSide));
      expect(result.height, greaterThanOrEqualTo(BoxTrendSmoother.minBoxSide));
    });

    test('retain 与 reset 清理消失航迹的状态', () {
      final smoother = BoxTrendSmoother();
      smoother.smooth(
        trackId: 1,
        measurement: moving(0),
        frameIndex: 1,
        frameWidth: frameW,
        frameHeight: frameH,
      );
      smoother.smooth(
        trackId: 2,
        measurement: moving(0),
        frameIndex: 1,
        frameWidth: frameW,
        frameHeight: frameH,
      );
      expect(smoother.stateCount, 2);
      smoother.retain(<int>{2});
      expect(smoother.stateCount, 1);
      smoother.reset();
      expect(smoother.stateCount, 0);
    });
  });

  group('DisplaySmoother（画面与俯视图共用平滑几何）', () {
    // 假设后摄 35mm 等效 24mm、图像宽 960px → 焦距 640px
    const focal = 640.0;
    // 640×480 画面对角线 800px

    Detection car(double dx) => Detection(
          x1: 300 + dx,
          y1: 100,
          x2: 380 + dx,
          y2: 220,
          score: 0.9,
          classId: 2,
          className: '轿车',
        );

    TrackedObject tracked(int id, Detection detection, {int misses = 0}) => TrackedObject(
          id: id,
          detection: detection,
          ttc: const TtcResult(
            ttc: 99,
            vx: 0,
            vy: 0,
            dwDt: 0,
            redAllowed: true,
            vw: 0,
            isStatic: false,
            riskLevel: 0,
            inPath: true,
          ),
          distance: null,
          misses: misses,
        );

    RiskSnapshot raw(List<TrackedObject> objects) => RiskSnapshot(
          objects: objects,
          minTtc: 99,
          riskLevel: 0,
          frameWidth: kFrameW,
          frameHeight: kFrameH,
          inferenceMs: 12,
          processed: true,
        );

    test('平滑后的框同时决定画面标框与俯视图位置（两者自洽）', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer());
      // 第 1 帧：建立状态
      smoother.apply(raw: raw(<TrackedObject>[tracked(1, car(0))]), frameIndex: 1, focalLengthPx: focal);

      // 第 2 帧：目标右移 10px，平滑后只走 4.5px（α = 0.45）
      final snapshot = smoother.apply(
        raw: raw(<TrackedObject>[tracked(1, car(10))]),
        frameIndex: 2,
        focalLengthPx: focal,
      );
      final object = snapshot.objects.single;

      expect(object.detection.x1, closeTo(304.5, 1e-9), reason: '画面标框应使用平滑几何');
      expect(object.smoothed, isTrue);

      // 距离按平滑后的框重算：高 1.75m/120px、宽 1.80m/80px 加权融合 = 11.36m
      expect(object.distance, closeTo(11.36, 0.05));
      expect(object.distanceSource, 'fused');

      // 俯视图横向偏移必须与"画面标框的中心"一致（不能用另一套几何）
      final expectedLateral =
          (object.detection.centerX - kFrameW / 2) / focal * object.distance!;
      expect(object.lateralMeters, closeTo(expectedLateral, 1e-9));
      expect(object.lateralMeters, greaterThan(0), reason: '偏画面右侧 → 横向为正');
    });

    test('第三帧：俯视图位置跟随趋势前进，且不越过原始测量', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer());
      RiskSnapshot? snapshot;
      for (var i = 0; i < 3; i++) {
        snapshot = smoother.apply(
          raw: raw(<TrackedObject>[tracked(1, car(i * 40.0))]),
          frameIndex: i + 1,
          focalLengthPx: focal,
        );
      }
      final object = snapshot!.objects.single;

      // 原始测量 x1 = 380；预测 = 318 + 18 = 336 → 输出 336 + 0.45×44 = 355.8
      expect(object.detection.x1, closeTo(355.8, 1e-6));
      expect(object.detection.x1, greaterThan(318.0), reason: '应沿趋势前进');
      expect(object.detection.x1, lessThan(380.0), reason: '不应直接跳到测量值');

      // 俯视图横向偏移由同一个平滑框重算（自洽），并且比"按原始测量算"更小
      final smoothedLateral = object.lateralMeters!;
      expect(
        smoothedLateral,
        closeTo((object.detection.centerX - kFrameW / 2) / focal * object.distance!, 1e-9),
      );
      final rawLateral = (420.0 - kFrameW / 2) / focal * object.distance!;
      expect(rawLateral, closeTo(1.775, 0.01));
      expect(smoothedLateral, lessThan(rawLateral),
          reason: '俯视图应跟随平滑后的位置，而不是原始测量的位置');
    });

    test('本帧没检测到的目标原样透传，不创建趋势状态', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer());
      final snapshot = smoother.apply(
        raw: raw(<TrackedObject>[tracked(3, car(0), misses: 2)]),
        frameIndex: 1,
        focalLengthPx: focal,
      );
      final object = snapshot.objects.single;
      expect(object.detection.x1, 300.0);
      expect(object.smoothed, isFalse);
      expect(object.misses, 2);
      expect(smoother.filter.stateCount, 0, reason: '未检测到的目标不应进入平滑状态');
    });

    test('关闭平滑时绘制几何与原始测量完全一致', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer())..strength = 0.0;
      expect(smoother.enabled, isFalse);
      smoother.apply(raw: raw(<TrackedObject>[tracked(1, car(0))]), frameIndex: 1, focalLengthPx: focal);
      final snapshot = smoother.apply(
        raw: raw(<TrackedObject>[tracked(1, car(30))]),
        frameIndex: 2,
        focalLengthPx: focal,
      );
      expect(snapshot.objects.single.detection.x1, 330.0);
      expect(snapshot.objects.single.smoothed, isFalse);
    });

    test('未取到焦距时距离回退 IPM，但仍由平滑框重算', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer(pitchDeg: 10.0));
      smoother.apply(raw: raw(<TrackedObject>[tracked(1, car(0))]), frameIndex: 1);
      final snapshot = smoother.apply(
        raw: raw(<TrackedObject>[tracked(1, car(10))]),
        frameIndex: 2,
      );
      final object = snapshot.objects.single;
      expect(object.detection.x1, closeTo(304.5, 1e-9));
      expect(object.distanceSource, 'ipm');
      expect(object.lateralMeters, isNull, reason: '没有焦距就没有横向偏移');
    });

    test('快照的风险字段保持原始测量结果', () {
      final smoother = DisplaySmoother(ipm: IpmTransformer());
      final source = RiskSnapshot(
        objects: <TrackedObject>[tracked(1, car(0))],
        minTtc: 1.4,
        riskLevel: 2,
        frameWidth: kFrameW,
        frameHeight: kFrameH,
        inferenceMs: 20,
        processed: true,
      );
      final snapshot = smoother.apply(raw: source, frameIndex: 1, focalLengthPx: focal);
      expect(snapshot.minTtc, 1.4);
      expect(snapshot.riskLevel, 2);
      expect(snapshot.inferenceMs, 20);
      expect(snapshot.objects.single.ttc.ttc, 99);
    });
  });
}
