/// v1.1.0 新增能力的回归测试（无需设备，`flutter test` 即可运行）：
/// * 俯视图标识与形态（`bev_icons.dart` / `bev_view_mode.dart` / `bev_view.dart`）；
/// * 相对速度（由 TTC 估计，`core/relative_speed.dart`）；
/// * 两轮车大类的尺寸标定与类别收录；
/// * 远距（长焦）目标过滤与长焦镜头挑选（`pipeline/far_target_engine.dart` /
///   `core/telephoto_channel.dart`）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastguard_mobile/core/camera_optics.dart';
import 'package:fastguard_mobile/core/distance_estimator.dart';
import 'package:fastguard_mobile/core/frame_crop.dart';
import 'package:fastguard_mobile/core/ipm.dart';
import 'package:fastguard_mobile/core/relative_speed.dart';
import 'package:fastguard_mobile/core/telephoto_channel.dart';
import 'package:fastguard_mobile/core/tracker.dart';
import 'package:fastguard_mobile/core/ttc_calculator.dart';
import 'package:fastguard_mobile/inference/model_assets.dart';
import 'package:fastguard_mobile/inference/yolo_detector.dart';
import 'package:fastguard_mobile/pipeline/far_target_engine.dart';
import 'package:fastguard_mobile/pipeline/inference_engine.dart';
import 'package:fastguard_mobile/settings.dart';
import 'package:fastguard_mobile/ui/bev_icons.dart';
import 'package:fastguard_mobile/ui/bev_view.dart';
import 'package:fastguard_mobile/ui/bev_view_mode.dart';
import 'package:fastguard_mobile/ui/home_screen.dart' show EngineState;
import 'package:fastguard_mobile/ui/settings_drawer.dart';

Detection box({
  required int classId,
  required String className,
  double x = 300,
  double y = 200,
  double size = 40,
}) =>
    Detection(
      x1: x,
      y1: y,
      x2: x + size,
      y2: y + size,
      score: 0.9,
      classId: classId,
      className: className,
    );

TtcResult ttcResult({double ttc = 99.0, int riskLevel = 0, bool inPath = true}) => TtcResult(
      ttc: ttc,
      vx: 0,
      vy: 0,
      dwDt: 0,
      redAllowed: true,
      vw: 0,
      isStatic: false,
      riskLevel: riskLevel,
      inPath: inPath,
    );

void main() {
  group('BEV 类别标识', () {
    test('COCO 类别 → 标识映射覆盖全部关注类别', () {
      expect(bevIconKindFor(0), BevIconKind.person);
      expect(bevIconKindFor(1), BevIconKind.bicycle);
      expect(bevIconKindFor(2), BevIconKind.car);
      expect(bevIconKindFor(3), BevIconKind.motorcycle);
      expect(bevIconKindFor(5), BevIconKind.bus);
      expect(bevIconKindFor(7), BevIconKind.truck);
      expect(bevIconKindFor(9), BevIconKind.unknown, reason: '红绿灯等未标定类别用兜底标识');
    });

    test('每个标识都有中文名，且两轮车标识互不相同', () {
      for (final kind in BevIconKind.values) {
        expect(bevIconKindLabel(kind), isNotEmpty);
      }
      expect(bevIconKindFor(1), isNot(bevIconKindFor(3)));
      expect(bevIconKindLabel(bevIconKindFor(1)), '自行车');
      expect(bevIconKindLabel(bevIconKindFor(3)), '摩托车');
    });
  });

  group('BevViewMode（扇形 / 方形）', () {
    test('默认方形，切换后为扇形，再切回方形', () {
      expect(BevViewMode.rectangular.toggled, BevViewMode.sector);
      expect(BevViewMode.sector.toggled, BevViewMode.rectangular);
      expect(BevViewMode.rectangular.label, '方形');
      expect(BevViewMode.sector.label, '扇形');
    });

    test('从持久化字符串解析，未知值回退方形', () {
      expect(BevViewMode.fromName('sector'), BevViewMode.sector);
      expect(BevViewMode.fromName('rectangular'), BevViewMode.rectangular);
      expect(BevViewMode.fromName(null), BevViewMode.rectangular);
      expect(BevViewMode.fromName('circle'), BevViewMode.rectangular);
    });
  });

  group('RelativeSpeedEstimator（相对速度由 TTC 估计）', () {
    test('无风险时相对速度为 0', () {
      final estimator = RelativeSpeedEstimator();
      final speed = estimator.update(trackId: 1, frameIndex: 1, distance: 20, ttc: 99);
      expect(speed, 0.0);
    });

    test('有风险时按 距离 ÷ TTC 估计，并做 EMA 平滑', () {
      final estimator = RelativeSpeedEstimator(emaAlpha: 0.35);
      // 20m / 4s = 5 m/s
      expect(estimator.update(trackId: 1, frameIndex: 1, distance: 20, ttc: 4), closeTo(5, 1e-9));
      // 下一帧不再接近：瞬时值 0，平滑后 = 0.65 × 5
      expect(
        estimator.update(trackId: 1, frameIndex: 2, distance: 20, ttc: 99),
        closeTo(3.25, 1e-9),
      );
      expect(estimator.speedFor(1), closeTo(3.25, 1e-9));
    });

    test('距离缺失或非法时不产生速度', () {
      final estimator = RelativeSpeedEstimator();
      expect(estimator.update(trackId: 2, frameIndex: 1, distance: null, ttc: 2), 0.0);
      expect(estimator.update(trackId: 3, frameIndex: 1, distance: 0, ttc: 2), 0.0);
    });

    test('速度被钳位到合理上限', () {
      final estimator = RelativeSpeedEstimator(maxReasonableMps: 80);
      expect(estimator.update(trackId: 4, frameIndex: 1, distance: 100, ttc: 0.5), 80.0);
    });

    test('中断过久后重新起头（不沿用旧速度）', () {
      final estimator = RelativeSpeedEstimator(maxFrameGap: 3);
      estimator.update(trackId: 5, frameIndex: 1, distance: 20, ttc: 4); // 5 m/s
      // 间隔 10 帧（超过容忍）：应直接从 0 起头，而不是 0.65 × 5
      expect(estimator.update(trackId: 5, frameIndex: 11, distance: 20, ttc: 99), 0.0);
    });

    test('cleanStaleTracks 清理消失目标', () {
      final estimator = RelativeSpeedEstimator();
      estimator.update(trackId: 6, frameIndex: 1, distance: 20, ttc: 4);
      expect(estimator.speedFor(6), greaterThan(0));
      estimator.cleanStaleTracks(<int>{});
      expect(estimator.speedFor(6), 0.0);
      estimator.reset();
      expect(estimator.speedFor(6), 0.0);
    });
  });

  group('两轮车大类', () {
    test('自行车与摩托车都在关注类别里', () {
      expect(focusClassNames.containsKey(1), isTrue);
      expect(focusClassNames.containsKey(3), isTrue);
      expect(focusClassNames[1], '自行车');
      expect(focusClassNames[3], '摩托车');
    });

    test('尺寸按需求给定：高 0.5 / 宽 0.3 / 长 1.75–2.5', () {
      for (final classId in twoWheelerClassIds) {
        final metrics = objectMetrics[classId];
        expect(metrics, isNotNull, reason: '两轮车类别 $classId 必须有尺寸标定，否则不参与测距');
        expect(metrics!.heightM, 0.5);
        expect(metrics.widthM, 0.3);
        expect(metrics.lengthsM.first, 1.75);
        expect(metrics.lengthsM.last, 2.5);
        expect(metrics.lengthsM, orderedEquals(<double>[1.75, 2.00, 2.25, 2.50]));
      }
    });

    test('两轮车能按给定尺寸估出距离（不再因为没有标定而被跳过）', () {
      const focalPx = 640.0;
      final detection = box(classId: 1, className: '自行车', size: 40);
      final estimate = const MonocularDistanceEstimator().estimate(
        detection,
        focalLengthPx: focalPx,
        frameWidth: 640,
        frameHeight: 480,
      );
      expect(estimate, isNotNull);
      expect(estimate!.meters, greaterThan(0));
      expect(estimate.meters, lessThan(MonocularDistanceEstimator.maxReliableMeters));
      // 高 0.5m / 40px × 640px = 8m（宽度一路为 0.3m/40px × 640 = 4.8m，融合值介于两者之间）
      expect(estimate.meters, closeTo(6.4, 1.6));
    });
  });

  group('远距目标过滤', () {
    FarTarget far(double distance) => FarTarget(
          id: distance.toInt(),
          detection: box(classId: 2, className: '轿车'),
          distanceM: distance,
        );

    test('只保留达到阈值的目标（含恰好等于阈值）', () {
      final all = <FarTarget>[far(20), far(40), far(40.5), far(60)];
      final kept = filterFarTargets(all, 40);
      expect(kept.map((target) => target.distanceM).toList(), <double>[40, 40.5, 60]);
      expect(filterFarTargets(all, 100), isEmpty);
    });

    test('FarTargetEngine 把太近的目标计入 nearCount 而不输出', () {
      final engine = FarTargetEngine(thresholdM: 20);
      // 40px 的轿车 → 高一路 1.75/40×640 ≈ 28m（>20），宽度一路 1.8/40×640 ≈ 28.8m
      final farSnapshot = engine.process(
        detections: <Detection>[box(classId: 2, className: '轿车', size: 30)],
        frameWidth: 640,
        frameHeight: 480,
        inferenceMs: 8,
        ipm: IpmTransformer(),
        focalLengthPx: 640,
      );
      expect(farSnapshot.targets.length, 1);
      expect(farSnapshot.targets.first.distanceM, greaterThan(20));
      expect(farSnapshot.nearCount, 0);
      expect(farSnapshot.thresholdM, 20);

      // 放大到 100px → 距离骤降到约 11m，应被阈值挡掉
      final nearSnapshot = engine.process(
        detections: <Detection>[box(classId: 2, className: '轿车', size: 100)],
        frameWidth: 640,
        frameHeight: 480,
        inferenceMs: 8,
        ipm: IpmTransformer(),
        focalLengthPx: 640,
      );
      expect(nearSnapshot.targets, isEmpty);
      expect(nearSnapshot.nearCount, 1);
    });

    test('未取到焦距时退回 IPM，仍能给出远距距离', () {
      final engine = FarTargetEngine(thresholdM: 20);
      final snapshot = engine.process(
        detections: <Detection>[box(classId: 2, className: '轿车', y: 470, size: 30)],
        frameWidth: 640,
        frameHeight: 480,
        inferenceMs: 8,
        ipm: IpmTransformer(),
        focalLengthPx: null,
      );
      expect(snapshot.processed, isTrue);
      for (final target in snapshot.targets) {
        expect(target.distanceSource, 'ipm');
      }
    });
  });

  group('长焦镜头挑选', () {
    BackCameraInfo camera(
      String id,
      double? focal35mmEq, {
      bool concurrent = true,
      bool logical = false,
    }) =>
        BackCameraInfo(
          id: id,
          optics: CameraOptics(
            cameraId: id,
            focalLengthsMm: const <double>[5.0],
            focalLength35mmEq: focal35mmEq,
          ),
          isLogicalMultiCamera: logical,
          concurrentSupported: concurrent,
        );

    test('挑 35mm 等效焦距最大的非主摄镜头', () {
      final cameras = <BackCameraInfo>[
        camera('0', 24),
        camera('1', 50),
        camera('3', 77),
      ];
      final picked = pickTelephotoCamera(cameras, mainCameraId: '0');
      expect(picked?.id, '3');
    });

    test('主摄即使等效焦距更大也不会被选为长焦', () {
      final cameras = <BackCameraInfo>[
        camera('0', 200),
        camera('3', 77),
      ];
      expect(pickTelephotoCamera(cameras, mainCameraId: '0')?.id, '3');
    });

    test('不支持并发流的镜头默认被排除', () {
      final cameras = <BackCameraInfo>[
        camera('0', 24),
        camera('3', 77, concurrent: false),
      ];
      expect(pickTelephotoCamera(cameras, mainCameraId: '0'), isNull);
      expect(
        pickTelephotoCamera(cameras, mainCameraId: '0', preferConcurrent: false)?.id,
        '3',
      );
    });

    test('拿不到 35mm 等效焦距的镜头不可用', () {
      final cameras = <BackCameraInfo>[
        camera('0', 24),
        camera('3', null),
      ];
      expect(pickTelephotoCamera(cameras, mainCameraId: '0'), isNull);
    });

    test('并列焦距时优先非逻辑多摄（物理子摄画面更干净）', () {
      final cameras = <BackCameraInfo>[
        camera('0', 24),
        camera('1', 77, logical: true),
        camera('2', 77),
      ];
      expect(pickTelephotoCamera(cameras, mainCameraId: '0')?.id, '2');
    });

    test('相机列表为空时返回 null（远距模式不可用）', () {
      expect(pickTelephotoCamera(const <BackCameraInfo>[], mainCameraId: '0'), isNull);
    });
  });

  group('AppSettings（俯视图形态与远距阈值）', () {
    test('默认方形、远距默认关闭且阈值 40m', () {
      final settings = AppSettings();
      expect(settings.bevViewMode, BevViewMode.rectangular);
      expect(settings.farTargetEnabled, isFalse);
      expect(settings.farDistanceThresholdM, 40.0);
    });

    test('copy / copyFrom 覆盖新增字段', () {
      final original = AppSettings(bevViewMode: BevViewMode.sector);
      final draft = original.copy()..farTargetEnabled = true;
      expect(original.farTargetEnabled, isFalse, reason: 'copy 必须是深拷贝');
      expect(draft.bevViewMode, BevViewMode.sector);
      expect(draft.farTargetEnabled, isTrue);

      final target = AppSettings();
      target.copyFrom(AppSettings(bevViewMode: BevViewMode.sector, farTargetEnabled: true));
      expect(target.bevViewMode, BevViewMode.sector);
      expect(target.farTargetEnabled, isTrue);
    });

    test('远距阈值被规整到候选档位（设置栏是分段按钮）', () {
      expect(AppSettings(farDistanceThresholdM: 5).normalized().farDistanceThresholdM, 20);
      expect(AppSettings(farDistanceThresholdM: 45).normalized().farDistanceThresholdM, 40);
      expect(AppSettings(farDistanceThresholdM: 500).normalized().farDistanceThresholdM, 80);
      for (final choice in kFarDistanceChoices) {
        expect(AppSettings(farDistanceThresholdM: choice).normalized().farDistanceThresholdM,
            choice);
      }
    });

    test('summary 反映俯视图形态与远距开关', () {
      expect(AppSettings().summary, contains('俯视方形'));
      expect(AppSettings(bevViewMode: BevViewMode.sector).summary, contains('俯视扇形'));
      expect(AppSettings(farTargetEnabled: true).summary, contains('远距 40m+'));
      expect(AppSettings().summary, isNot(contains('远距')));
    });
  });

  group('BevView 绘制', () {
    final snapshot = RiskSnapshot(
      objects: <TrackedObject>[
        TrackedObject(
          id: 1,
          detection: box(classId: 2, className: '轿车', size: 60),
          ttc: ttcResult(ttc: 1.4, riskLevel: 2),
          distance: 12.5,
          distanceSource: 'fused',
          lateralMeters: 1.2,
          relativeSpeedMps: 4.2,
        ),
        TrackedObject(
          id: 2,
          detection: box(classId: 1, className: '自行车', size: 30),
          ttc: ttcResult(),
          distance: 55,
          distanceSource: 'height',
          lateralMeters: -3.0,
        ),
      ],
      minTtc: 1.4,
      riskLevel: 2,
      frameWidth: 640,
      frameHeight: 480,
      inferenceMs: 12,
      processed: true,
    );

    final farTargets = FarTargetSnapshot(
      targets: <FarTarget>[
        FarTarget(
          id: 9,
          detection: box(classId: 7, className: '卡车', size: 24),
          distanceM: 62,
          lateralMeters: 2.4,
        ),
      ],
      frameWidth: 640,
      frameHeight: 480,
      inferenceMs: 9,
      processed: true,
      thresholdM: 40,
    );

    testWidgets('方形与扇形两种形态都能绘制（含超出范围的目标与远距目标）', (tester) async {
      for (final mode in BevViewMode.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  height: 200,
                  child: BevView(
                    snapshot: snapshot,
                    farTargets: farTargets,
                    mode: mode,
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: '${mode.label}形态绘制不应抛异常');
        expect(find.byType(BevView), findsOneWidget);
      }
    });

    testWidgets('无目标时也能绘制（空快照）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 160,
              child: BevView(snapshot: null),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('右上角按钮可切换形态（提示文案随当前形态变化）', (tester) async {
      var taps = 0;
      Widget build(BevViewMode mode) => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 260,
                  height: 200,
                  child: BevView(
                    snapshot: null,
                    mode: mode,
                    onToggleMode: () => taps += 1,
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(build(BevViewMode.rectangular));
      await tester.tap(find.byTooltip('切换为扇形视图'));
      await tester.pump();
      expect(taps, 1);

      await tester.pumpWidget(build(BevViewMode.sector));
      await tester.tap(find.byTooltip('切换为方形视图'));
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('未提供切换回调时不显示按钮', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 160,
              child: BevView(snapshot: null),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.radar), findsNothing);
      expect(find.byIcon(Icons.grid_on), findsNothing);
    });
  });

  group('设置栏（多层级 + 新增项接线）', () {
    Future<void> pumpDrawer(WidgetTester tester, AppSettings settings,
        {String? farCameraLabel, String? farReason, String? farFallbackNote}) async {
      // 设置栏是长列表：把测试窗口加高，让所有条目都被构建，才能断言靠下的内容
      await tester.binding.setSurfaceSize(const Size(420, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsDrawer(
              settings: settings,
              engineState: EngineState.running,
              message: '推理在手机本地完成',
              snapshot: null,
              optics: null,
              focalLengthPx: null,
              modelAssetKey: kModelAssetFp32,
              farSnapshot: null,
              farCameraLabel: farCameraLabel,
              farUnavailableReason: farReason,
              farFallbackNote: farFallbackNote,
              farFocalLengthPx: 1820,
              onChanged: (AppSettings updated) async {},
              onReset: () async {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pump();
    }

    /// 进入某个一级分组（点分组条目）。
    Future<void> enter(WidgetTester tester, String group) async {
      await tester.tap(find.text(group));
      await tester.pumpAndSettle();
    }

    testWidgets('一级是分组列表，二级才是具体设置项', (tester) async {
      await pumpDrawer(tester, AppSettings());
      expect(tester.takeException(), isNull);
      // 一级：分组标题可见，具体设置项不可见
      expect(find.text('设置'), findsOneWidget);
      for (final group in <String>[
        '摄像头',
        '检测与告警',
        '推理与模型',
        '显示与俯视图',
        '标框平滑',
        '远距监测',
        '运行状态',
        '关于',
      ]) {
        expect(find.text(group), findsOneWidget, reason: '缺少一级分组：$group');
      }
      expect(find.text('显示俯视图（BEV）'), findsNothing);
      expect(find.text('开启远距监测'), findsNothing);

      // 二级：进入「显示与俯视图」后才有具体设置项，并能返回一级
      await enter(tester, '显示与俯视图');
      expect(find.text('显示俯视图（BEV）'), findsOneWidget);
      expect(find.text('显示全部 80 类目标'), findsOneWidget);
      await tester.tap(find.byTooltip('返回上一层'));
      await tester.pumpAndSettle();
      expect(find.text('显示俯视图（BEV）'), findsNothing);
      expect(find.text('远距监测'), findsOneWidget);
    });

    testWidgets('一级分组副标题显示当前值（不进去也能核对）', (tester) async {
      await pumpDrawer(
        tester,
        AppSettings(
          cameraIndex: 1,
          confidence: 0.5,
          inferenceSize: 416,
          useInt8Model: true,
          bevViewMode: BevViewMode.sector,
          farTargetEnabled: true,
        ),
      );
      expect(find.textContaining('摄像头 1'), findsOneWidget);
      expect(find.textContaining('置信度 0.50'), findsOneWidget);
      expect(find.textContaining('416px'), findsOneWidget);
      expect(find.textContaining('INT8'), findsOneWidget);
      expect(find.textContaining('扇形'), findsOneWidget);
    });

    testWidgets('远距监测二级页渲染来源与阈值', (tester) async {
      await pumpDrawer(
        tester,
        AppSettings(farTargetEnabled: true),
        farCameraLabel: '相机 3 · 物理焦距 6.00 mm · 77.0mm(35mm等效)',
      );
      await enter(tester, '远距监测');
      expect(tester.takeException(), isNull);
      expect(find.text('开启远距监测'), findsOneWidget);
      expect(find.text('扇形'), findsNothing);
      expect(find.textContaining('长焦：相机 3'), findsOneWidget);
      expect(find.textContaining('远距阈值 40 m'), findsOneWidget);
      expect(find.textContaining('2:1'), findsOneWidget);
    });

    testWidgets('长焦不可用时二级页显示原因', (tester) async {
      await pumpDrawer(
        tester,
        AppSettings(farTargetEnabled: true),
        farReason: '后置镜头不支持与主摄并发取流（远距模式不可用）',
      );
      await enter(tester, '远距监测');
      expect(find.textContaining('后置镜头不支持与主摄并发取流'), findsOneWidget);
    });

    testWidgets('回退到主摄裁切时显示回退说明', (tester) async {
      await pumpDrawer(
        tester,
        AppSettings(farTargetEnabled: true),
        farFallbackNote: '未找到后置长焦镜头（远距模式不可用），已改用主摄中心裁切 ×3.0',
      );
      await enter(tester, '远距监测');
      expect(find.textContaining('已回退'), findsOneWidget);
      expect(find.textContaining('主摄中心裁切 ×3.0'), findsWidgets);
    });

    testWidgets('显示与俯视图页可切换形态，注释说明当前形态', (tester) async {
      await pumpDrawer(tester, AppSettings(bevViewMode: BevViewMode.sector));
      await enter(tester, '显示与俯视图');
      expect(find.text('扇形'), findsOneWidget);
      expect(find.text('方形'), findsOneWidget);
      expect(find.textContaining('同心距离圈'), findsOneWidget);
    });

    testWidgets('运行状态页汇总各功能状态', (tester) async {
      await pumpDrawer(
        tester,
        AppSettings(boxSmoothing: false, showBev: false, farTargetEnabled: false),
      );
      await enter(tester, '运行状态');
      expect(tester.takeException(), isNull);
      expect(find.textContaining('标框平滑：关闭'), findsOneWidget);
      expect(find.textContaining('俯视图：未显示'), findsOneWidget);
      expect(find.textContaining('远距监测：关闭'), findsOneWidget);
    });

    testWidgets('关于页显示版本号', (tester) async {
      await pumpDrawer(tester, AppSettings());
      await enter(tester, '关于');
      expect(find.textContaining(kAppVersion), findsOneWidget);
      expect(find.textContaining(kModelAssetFp32), findsOneWidget);
    });
  });

  group('主摄中心裁切（数字变焦回退）', () {
    /// 造一张 W×H 的图，每个像素的 R 通道 = 列号 % 256、G = 行号 % 256，便于核对裁切位置。
    (Uint8List, int, int) makeImage(int w, int h) {
      final rgb = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          rgb[i] = x % 256;
          rgb[i + 1] = y % 256;
          rgb[i + 2] = 7;
        }
      }
      return (rgb, w, h);
    }

    test('按倍数取出中心区域，且实际倍数与像素比一致', () {
      final (rgb, w, h) = makeImage(720, 540);
      final crop = cropCenterRgb(rgb: rgb, width: w, height: h, zoom: 3.0);
      expect(crop.width, 240);
      expect(crop.height, 180);
      expect(crop.rgb.length, 240 * 180 * 3);
      expect(crop.zoom, closeTo(3.0, 1e-9));
    });

    test('裁的确实是中心：左上角像素等于原图中心偏移处的像素', () {
      final (rgb, w, h) = makeImage(720, 540);
      final crop = cropCenterRgb(rgb: rgb, width: w, height: h, zoom: 3.0);
      // 中心裁切：left = (720-240)/2 = 240，top = (540-180)/2 = 180
      expect(crop.rgb[0], 240 % 256);
      expect(crop.rgb[1], 180 % 256);
      // 右下角像素 = (240+239, 180+179)
      final last = crop.rgb.length - 3;
      expect(crop.rgb[last], (240 + 239) % 256);
      expect(crop.rgb[last + 1], (180 + 179) % 256);
    });

    test('zoom ≤ 1 或非法参数时原样返回整帧', () {
      final (rgb, w, h) = makeImage(64, 48);
      for (final zoom in <double>[1.0, 0.5, 0.0]) {
        final crop = cropCenterRgb(rgb: rgb, width: w, height: h, zoom: zoom);
        expect(crop.zoom, 1.0);
        expect(crop.width, w);
        expect(identical(crop.rgb, rgb), isTrue, reason: '不应复制整帧');
      }
      final zero = cropCenterRgb(rgb: rgb, width: 0, height: 0, zoom: 3.0);
      expect(zero.width, 0);
    });

    test('非整数倍数时用实际像素比作为 zoom（避免距离系统偏差）', () {
      final (rgb, w, h) = makeImage(720, 540);
      final crop = cropCenterRgb(rgb: rgb, width: w, height: h, zoom: 2.7);
      expect(crop.width, 267); // (720/2.7).round() = 267
      expect(crop.zoom, closeTo(720 / 267, 1e-9));
    });

    test('RGB 数据长度不足时抛 ArgumentError（尽早暴露调用错误）', () {
      expect(
        () => cropCenterRgb(rgb: Uint8List(10), width: 64, height: 48, zoom: 3.0),
        throwsArgumentError,
      );
    });

    test('远距来源枚举有可读标签', () {
      expect(FarSource.telephoto.label, contains('长焦'));
      expect(FarSource.mainCrop.label, contains('裁切'));
    });
  });
}
