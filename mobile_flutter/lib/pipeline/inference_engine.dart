/// 端上推理管线：相机帧 → YOLO11n(ONNX) → 航迹稳定 → TTC 风险 → 供界面绘制的快照。
///
/// 这是 PC 端 `core/video_thread.py` 在移动端的对应物，但**全部在手机本地完成**：
/// 采集帧在这里被直接推理，不再经过网络传输，也没有"预处理图像增强"分支。
library;

import 'package:flutter/foundation.dart';

import '../core/box_smoother.dart';
import '../core/camera_optics.dart';
import '../core/distance_estimator.dart';
import '../core/frame_crop.dart';
import '../core/ipm.dart';
import '../core/relative_speed.dart';
import '../core/tracker.dart';
import '../core/ttc_calculator.dart';
import '../inference/model_assets.dart';
import '../inference/yolo_detector.dart';
import '../settings.dart';
import 'far_target_engine.dart';

/// 远距（长焦）目标的取数来源。
enum FarSource {
  /// 后置**长焦**并发双流（首选；要求设备 HAL 支持并发且不隐藏长焦）。
  telephoto,

  /// 主摄**中心裁切**（数字变焦）：长焦不可用时的回退，任何设备都能用。
  mainCrop;

  String get label => this == FarSource.telephoto ? '长焦并发' : '主摄中心裁切（数字变焦）';
}

/// 带风险信息的目标。
class TrackedObject {
  const TrackedObject({
    required this.id,
    required this.detection,
    required this.ttc,
    required this.distance,
    this.distanceSource,
    this.lateralMeters,
    this.relativeSpeedMps = 0.0,
    this.misses = 0,
    this.smoothed = false,
  });

  final int id;

  /// **绘制用**几何。
  ///
  /// 默认就是本帧的测量值；开启「标框平滑」后，这里是"用前两帧运动趋势外推到本帧、
  /// 再按平滑强度回拉"的结果（见 [BoxTrendSmoother]）。TTC 与风险分级仍基于
  /// **未平滑**的原始测量，因此这里只影响画面标框与俯视图的位置。
  final Detection detection;

  final TtcResult ttc;

  /// IPM 估计的前方距离（米），无法估计时为 null。
  final double? distance;

  /// 距离的来源：`fused`（高/宽两路融合）、`height`、`width`、`ipm`（回退）。
  final String? distanceSource;

  /// 相对镜头光轴的横向偏移（米，右为正）；供俯视图（BEV）定位目标。
  final double? lateralMeters;

  /// **接近速度**（m/s，正 = 正在靠近本车），由 `距离 ÷ TTC` 估计并做 EMA 平滑。
  ///
  /// 无接近趋势（TTC 为安全值）或未估出距离时为 0。**不参与风险分级**
  /// （分级仍由 [TtcResult] 决定），只用于界面展示"相对速度"。
  final double relativeSpeedMps;

  /// 该目标连续未被检测到的帧数；>0 表示当前帧并没有真的看到它
  /// （航迹仍在，但不应再画框，否则会出现停在原地的"残影框"）。
  final int misses;

  /// 本帧的绘制几何是否来自趋势外推（用于调试显示与测试断言）。
  final bool smoothed;

  int get riskLevel => ttc.riskLevel;

  /// 本帧是否真的检测到该目标（可安全绘制）。
  bool get isFresh => misses == 0;
}

/// 单帧分析结果（界面据此绘制）。
class RiskSnapshot {
  const RiskSnapshot({
    required this.objects,
    required this.minTtc,
    required this.riskLevel,
    required this.frameWidth,
    required this.frameHeight,
    required this.inferenceMs,
    required this.processed,
  });

  final List<TrackedObject> objects;

  /// 最危险的 TTC（秒）；[TtcCalculator.safeTtc] 表示无风险。
  final double minTtc;

  /// 0 = 安全，1 = 注意，2 = 危险。
  final int riskLevel;

  final int frameWidth;
  final int frameHeight;

  /// 本次推理耗时（毫秒），仅用于调试显示。
  final double inferenceMs;

  /// 本帧是否真正跑了推理（节流时会复用上一帧结果）。
  final bool processed;

  bool get hasObjects => objects.isNotEmpty;
}

/// 端上推理引擎。
class InferenceEngine {
  InferenceEngine(this._settings) {
    _detector = YoloOnnxDetector(
      inputSize: _settings.inferenceSize,
      confThreshold: _settings.confidence,
      iouThreshold: _settings.iouThreshold,
      focusOnly: !_settings.showAllClasses,
    );
    _farEngine.thresholdM = _settings.farDistanceThresholdM;
    _syncDisplaySmoothing();
  }

  final AppSettings _settings;
  late final YoloOnnxDetector _detector;
  final SimpleTracker _tracker = SimpleTracker();
  TtcCalculator _ttc = TtcCalculator(fps: kDefaultFps);
  final IpmTransformer _ipm = IpmTransformer();

  /// 相对速度（接近速度）估计：直接从 `距离 ÷ TTC` 得出，见 `core/relative_speed.dart`。
  final RelativeSpeedEstimator _relativeSpeed = RelativeSpeedEstimator();

  /// 远距（长焦）检测引擎；仅在 [AppSettings.farTargetEnabled] 时使用。
  final FarTargetEngine _farEngine = FarTargetEngine();

  /// 主摄:长焦 的推理配比 = **2:1**（每处理 2 帧主摄，允许处理 1 帧长焦）。
  ///
  /// 长焦只负责"补远远处"，没必要与主摄争抢同一份算力；未轮到长焦时直接丢帧
  /// （长焦本来就是低频辅助通道，不排队追赶）。
  static const int telephotoEveryNMainFrames = 2;

  /// 主摄推理帧计数（自上次处理长焦帧起）。
  int _mainFramesSinceTelephoto = 0;

  /// 长焦光学参数（25mm 等效焦距用于把长焦像素换算成距离）。
  CameraOptics? _telephotoOptics;
  double? _telephotoFocalLengthPx;

  /// ONNX 会话是**单例**：主摄与长焦共用同一个模型，因此 detect 必须串行。
  /// 主摄在途时到达的长焦帧直接丢弃（见 [processTelephotoFrame]）。
  bool _detectBusy = false;

  /// 最近一帧长焦结果（未开启远距监测时为 null）。
  FarTargetSnapshot? _lastFarSnapshot;
  FarTargetSnapshot? get lastFarSnapshot => _lastFarSnapshot;

  /// 远距监测的取数来源：真长焦并发（首选）或主摄中心裁切（回退）。
  FarSource _farSource = FarSource.telephoto;

  /// 当前远距监测用的来源（界面据此显示"长焦"还是"主摄中心裁切"）。
  FarSource get farSource => _farSource;

  /// 切换来源时会重置远距航迹：两路的画面尺寸/视角不同，混在一起会互相污染。
  set farSource(FarSource value) {
    if (_farSource == value) {
      return;
    }
    _farSource = value;
    resetFarTargets();
  }

  /// 针孔测距（真实尺寸 + 真实焦距），优先使用；不可用时退回 IPM。
  final MonocularDistanceEstimator _focalEstimator = const MonocularDistanceEstimator();

  /// 绘制平滑层：**只替换绘制几何**（画面标框与俯视图共用同一份结果），
  /// TTC 与风险分级仍然使用未平滑的原始测量。
  late final DisplaySmoother _display = DisplaySmoother(
    ipm: _ipm,
    estimator: _focalEstimator,
  );

  CameraOptics? _optics;

  /// 相机焦距（像素）；由设备光学参数与图像宽度算出。
  double? _focalLengthPx;

  /// 移动端图像流按节流后的处理频率估算（PC 端为 30 fps）。
  static const double kDefaultFps = 15.0;

  /// 与 [TtcCalculator.safeTtc] 一致：等于该值表示无碰撞风险。
  static const double safeTtc = 99.0;

  bool _ready = false;
  String? _error;
  RiskSnapshot? _lastSnapshot;
  int _frameCounter = 0;

  bool get isReady => _ready;
  String? get error => _error;
  AppSettings get settings => _settings;

  /// 加载模型（只需一次；切换精度时用 [switchModel]）。
  Future<void> initialize({String? assetKey}) async {
    final target = assetKey ?? modelAssetFor(int8: _settings.useInt8Model);
    try {
      await _detector.load(assetKey: target);
      _ready = true;
      _error = null;
      // 刻意不判断 kDebugMode：release 包也要能在 logcat 里确认**实际加载的是哪个模型**
      // （否则"测了 INT8 还是 FP32"无法从日志区分）
      debugPrint('[FastGuard] 模型已加载: $target');
    } catch (error) {
      _ready = false;
      _error = '$error';
      rethrow;
    }
  }

  /// 当前已加载的模型资产。
  String? get modelAssetKey => _detector.loadedAssetKey;

  /// 按 [AppSettings.useInt8Model] 期望的资产（用于判断是否需要重新加载）。
  String get desiredModelAsset => modelAssetFor(int8: _settings.useInt8Model);

  /// 是否需要重新加载模型（设置在界面改动后、真正切换前的判断依据）。
  bool get needsModelReload => modelAssetKey != desiredModelAsset;

  /// 切换模型精度：关闭旧会话 → 重建 → 重置航迹（旧航迹的宽度历史对新模型无意义）。
  ///
  /// 失败时**自动回退**到上一个可用的资产，避免用户被卡在"模型加载失败"状态。
  Future<void> switchModel({required String assetKey}) async {
    final previous = modelAssetKey;
    if (previous == assetKey) {
      return;
    }
    _ready = false;
    resetTracking();
    try {
      await initialize(assetKey: assetKey);
      debugPrint('[FastGuard] 模型已切换: $assetKey');
    } catch (error) {
      if (previous != null) {
        // 回退：把设置改回旧精度由调用方负责，这里先保证推理可用
        await initialize(assetKey: previous);
        debugPrint('[FastGuard] 模型切换失败，已回退到 $previous：$error');
      }
      rethrow;
    }
  }

  /// 推理图片大小变化时需要同步到检测器（模型为动态输入，无需重新导出）。
  void applySettings() {    _detector.inputSize = _settings.inferenceSize;
    _detector.confThreshold = _settings.confidence;
    _detector.iouThreshold = _settings.iouThreshold;
    _detector.focusOnly = !_settings.showAllClasses;
    _farEngine.thresholdM = _settings.farDistanceThresholdM;
    _syncDisplaySmoothing();
  }

  /// 把「标框平滑」设置同步到绘制平滑层（关闭时强度为 0，等价于不过滤）。
  void _syncDisplaySmoothing() {
    _display.strength = _settings.boxSmoothing ? _settings.boxSmoothingStrength : 0.0;
  }

  /// 摄像头切换后重置航迹，避免把新画面的目标关联到旧轨迹上。
  void resetTracking() {
    _tracker.reset();
    _ttc = TtcCalculator(fps: kDefaultFps);
    _relativeSpeed.reset();
    _display.reset();
    _lastSnapshot = null;
    _frameCounter = 0;
    _processedFrames = 0;
    resetFarTargets();
  }

  /// 重置远距（长焦）链路：切换/关闭长焦、或主摄切换后调用。
  void resetFarTargets() {
    _farEngine.reset();
    _lastFarSnapshot = null;
    _mainFramesSinceTelephoto = 0;
  }

  /// 设置/更新相机光学参数（相机切换后要重新读取），并据此刷新焦距(像素)。
  void setCameraOptics(CameraOptics? optics, {int? imageWidth}) {
    _optics = optics;
    final width = imageWidth ?? _lastImageWidth;
    _focalLengthPx = (optics != null && width != null && width > 0)
        ? optics.focalLengthPixels(width)
        : null;
    // 这两行刻意不判断 kDebugMode：release 包也需要在 logcat 里能确认测距依据
    debugPrint('[FastGuard] 相机光学: ${optics?.describe() ?? "未获取到（将回退 IPM）"}');
    debugPrint(
      '[FastGuard] 测距方式 = ${_focalLengthPx != null ? "针孔(真实尺寸+真实焦距)" : "IPM 回退"}'
      '，焦距(像素) = ${_focalLengthPx?.toStringAsFixed(1) ?? "-"}，图像宽度 = ${_lastImageWidth ?? "-"}',
    );
  }

  CameraOptics? get cameraOptics => _optics;
  double? get focalLengthPx => _focalLengthPx;

  /// 设置/更新**长焦**镜头的光学参数，并据此刷新长焦焦距(像素)。
  ///
  /// 长焦测距必须用长焦自己的焦距：同一像素尺寸在长焦下对应的实际距离远得多，
  /// 用主摄焦距会低估约 `f_tele / f_main` 倍。
  void setTelephotoOptics(CameraOptics? optics, {int? imageWidth}) {
    _telephotoOptics = optics;
    final width = imageWidth ?? _lastTelephotoWidth;
    _telephotoFocalLengthPx = (optics != null && width != null && width > 0)
        ? optics.focalLengthPixels(width)
        : null;
    debugPrint(
      '[FastGuard] 长焦光学: ${optics?.describe() ?? "未获取到（远距模式不可用）"}'
      '，焦距(像素) = ${_telephotoFocalLengthPx?.toStringAsFixed(1) ?? "-"}'
      '，图像宽度 = ${_lastTelephotoWidth ?? "-"}',
    );
  }

  CameraOptics? get telephotoOptics => _telephotoOptics;
  double? get telephotoFocalLengthPx => _telephotoFocalLengthPx;

  /// 处理一帧 RGB 数据；返回 null 表示本帧被节流跳过（复用上一帧结果）。
  Future<RiskSnapshot?> processFrame(Uint8List rgb, int width, int height) async {
    if (!_ready) {
      return null;
    }
    _frameCounter += 1;
    if (_frameCounter % _settings.processEveryNthFrame != 0 && _lastSnapshot != null) {
      return null;
    }
    // 本帧的**推理帧序号**：TTC 历史与标框平滑都拿它当时间基
    _processedFrames += 1;

    // 记住图像宽度：相机分辨率可能变化，焦距(像素) 依赖它
    if (_lastImageWidth != width) {
      _lastImageWidth = width;
      if (_optics != null) {
        setCameraOptics(_optics, imageWidth: width);
      }
    }

    final stopwatch = Stopwatch()..start();
    List<Detection> detections;
    _detectBusy = true;
    try {
      detections = await _detector.detect(rgb, width, height);
    } finally {
      _detectBusy = false;
    }
    final tracks = _tracker.update(detections, width, height);
    // 清理已消失目标的历史，防止长时间运行内存增长
    _ttc.cleanStaleTracks(_tracker.activeIds);

    final objects = <TrackedObject>[];
    var minTtc = safeTtc;
    var riskLevel = 0;

    for (final track in tracks) {
      final detection = track.detection;

      // 测距：优先针孔模型（真实尺寸 + 真实焦距，高低两路融合），不可用时退回 IPM
      final focalPx = _focalLengthPx;
      final estimate = estimateDistance(
        detection: detection,
        frameWidth: width,
        frameHeight: height,
        focalLengthPx: focalPx,
        estimator: _focalEstimator,
        ipm: _ipm,
      );
      final distance = estimate.meters;
      final distanceSource = estimate.source;

      final result = _ttc.update(
        trackId: track.id,
        width: detection.width,
        centerX: detection.centerX,
        centerY: detection.centerY,
        bottomY: detection.y2,
        frameW: width.toDouble(),
        frameH: height.toDouble(),
        areaRatio: detection.areaRatio(width, height),
        frameIndex: _processedFrames,
        distance: distance,
        useEma: true,
        emaAlpha: 0.3,
      );

      // 用可配置的告警阈值替换内部固定阈值（2.0s）
      final adjusted = _applyThreshold(result, _settings.ttcThreshold);
      // 只有本帧真正检测到的目标才参与"最高风险"判定与绘制，避免残影框误报
      if (track.misses == 0) {
        if (adjusted.ttc < minTtc) {
          minTtc = adjusted.ttc;
        }
        if (adjusted.riskLevel > riskLevel) {
          riskLevel = adjusted.riskLevel;
        }
      }
      // 俯视图定位：由"该目标距离 + 真实焦距"换算横向偏移
      final lateral = estimateLateralOffset(
        centerX: detection.centerX,
        imageWidth: width.toDouble(),
        focalLengthPx: focalPx,
        distanceM: distance,
      );

      objects.add(TrackedObject(
        id: track.id,
        detection: detection,
        ttc: adjusted,
        distance: distance,
        distanceSource: distanceSource,
        lateralMeters: lateral,
        relativeSpeedMps: _relativeSpeed.update(
          trackId: track.id,
          frameIndex: _processedFrames,
          distance: distance,
          ttc: adjusted.ttc,
        ),
        misses: track.misses,
      ));
    }

    _relativeSpeed.cleanStaleTracks(_tracker.activeIds);
    // 长焦每处理一帧就会推远一格配比；主摄也在跑，所以这里累计
    _mainFramesSinceTelephoto += 1;

    stopwatch.stop();
    var snapshot = RiskSnapshot(
      objects: objects,
      minTtc: minTtc,
      riskLevel: riskLevel,
      frameWidth: width,
      frameHeight: height,
      inferenceMs: stopwatch.elapsedMicroseconds / 1000.0,
      processed: true,
    );

    // 标框平滑：把绘制几何换成"前两帧趋势外推 + 平滑过渡"的结果。
    // 画面标框与俯视图都读同一个快照，因此两个视图同时得到平滑且位置始终一致；
    // TTC、风险分级、以及上面的 minTtc/riskLevel 都基于未平滑的原始测量。
    if (_display.enabled) {
      snapshot = _display.apply(
        raw: snapshot,
        frameIndex: _processedFrames,
        focalLengthPx: _focalLengthPx,
        activeTrackIds: _tracker.activeIds,
      );
    }
    _lastSnapshot = snapshot;

    // 诊断日志（约每 20 次推理一条，便于用 adb logcat 确认端上推理真的在出结果）
    if (_processedFrames % 20 == 1) {
      // 顺带打印最近目标的距离/横向偏移，便于核对测距是否合理（均为原始测量）
      TrackedObject? nearest;
      for (final object in objects) {
        if (!object.isFresh || object.distance == null) {
          continue;
        }
        if (nearest == null || object.distance! < nearest.distance!) {
          nearest = object;
        }
      }
      final nearestText = nearest == null
          ? '无目标'
          : '最近=${nearest.detection.className} '
              '${nearest.distance!.toStringAsFixed(1)}m'
              '(横向${nearest.lateralMeters?.toStringAsFixed(1) ?? "-"}m,'
              '${nearest.distanceSource ?? "-"})';
      final trendCount = snapshot.objects.where((object) => object.smoothed).length;
      debugPrint(
        '[FastGuard] 端上推理 frame=$_processedFrames '
        'input=${_settings.inferenceSize} '
        'detections=${detections.length} tracks=${tracks.length} '
        'objects=${objects.length} risk=$riskLevel '
        'ms=${snapshot.inferenceMs.toStringAsFixed(1)} '
        '平滑=$trendCount/${objects.length} $nearestText',
      );
    }
    return snapshot;
  }

  /// 已完成的推理帧计数（诊断用）。
  int _processedFrames = 0;
  int get processedFrames => _processedFrames;

  /// 最近一帧的图像宽度（焦距换算需要）。
  int? _lastImageWidth;

  /// 最近一帧长焦图像的宽度（长焦焦距换算需要）。
  int? _lastTelephotoWidth;

  /// 处理一帧**长焦**画面（RGB888）：远距目标只标距离，不参与 TTC / 画面标框。
  ///
  /// 返回 null 表示本帧被丢弃，原因有三（均为正常节流，不是错误）：
  /// * 未加载模型，或未开启远距监测；
  /// * 主摄:长焦 的 **2:1** 配比还没轮到长焦；
  /// * 主摄推理正在使用同一个 ONNX 会话（会话不能并发调用）。
  Future<FarTargetSnapshot?> processTelephotoFrame(
    Uint8List rgb,
    int width,
    int height,
  ) async {
    if (!_ready || !_settings.farTargetEnabled) {
      return null;
    }
    if (_mainFramesSinceTelephoto < telephotoEveryNMainFrames) {
      return null; // 2:1 配比：主摄先跑够帧数
    }
    if (_detectBusy) {
      return null; // 会话被主摄占用，直接丢帧（不排队追赶）
    }

    if (_lastTelephotoWidth != width) {
      _lastTelephotoWidth = width;
      if (_telephotoOptics != null) {
        setTelephotoOptics(_telephotoOptics, imageWidth: width);
      }
    }

    return _runFarInference(
      rgb: rgb,
      width: width,
      height: height,
      focalLengthPx: _telephotoFocalLengthPx,
      label: '长焦',
    );
  }

  /// 处理一帧**主摄中心裁切**（数字变焦）：长焦不可用时的远距监测回退。
  ///
  /// 直接复用主摄这一帧已经转好的 RGB（不再做一次 YUV→RGB），并按**同一套 2:1 配比**
  /// 决定是否真正推理：主摄自身已跑过一帧，这里只在"轮到远距"时再做一次裁切推理。
  ///
  /// 返回 null 表示本帧不做远距推理（未开启 / 没轮到 / 会话被占用 / 拿不到主摄焦距）。
  Future<FarTargetSnapshot?> processFarCropFrame(
    Uint8List rgb,
    int width,
    int height, {
    double zoom = kFarCropZoom,
  }) async {
    if (!_ready || !_settings.farTargetEnabled) {
      return null;
    }
    if (_mainFramesSinceTelephoto < telephotoEveryNMainFrames) {
      return null; // 2:1 配比：与长焦路径完全一致
    }
    if (_detectBusy) {
      return null;
    }
    final mainFocal = _focalLengthPx;
    if (mainFocal == null || mainFocal <= 0) {
      // 拿不到主摄真实焦距就给不出可信的远距，宁可不给（而不是给个错数）
      return null;
    }

    final crop = cropCenterRgb(rgb: rgb, width: width, height: height, zoom: zoom);
    return _runFarInference(
      rgb: crop.rgb,
      width: crop.width,
      height: crop.height,
      // 数字变焦后的等效焦距：同一像素尺寸在裁切图上对应更远的实际距离
      focalLengthPx: mainFocal * crop.zoom,
      label: '主摄裁切×${crop.zoom.toStringAsFixed(1)}',
    );
  }

  /// 远距推理的公共部分：串行化 detect → 航迹 + 测距 + 阈值过滤 → 诊断日志。
  Future<FarTargetSnapshot> _runFarInference({
    required Uint8List rgb,
    required int width,
    required int height,
    required double? focalLengthPx,
    required String label,
  }) async {
    final stopwatch = Stopwatch()..start();
    List<Detection> detections;
    _detectBusy = true;
    try {
      detections = await _detector.detect(rgb, width, height);
    } finally {
      _detectBusy = false;
    }

    final far = _farEngine.process(
      detections: detections,
      frameWidth: width,
      frameHeight: height,
      inferenceMs: stopwatch.elapsedMicroseconds / 1000.0,
      ipm: _ipm,
      focalLengthPx: focalLengthPx,
    );
    _mainFramesSinceTelephoto = 0;
    _lastFarSnapshot = far;

    if (_farFrameCounter % 20 == 1) {
      debugPrint(
        '[FastGuard] 远距($label) frame=$_farFrameCounter '
        '输入=${width}x$height 检测=${detections.length} '
        '远距=${far.targets.length} 近处=${far.nearCount} '
        '阈值=${far.thresholdM.toStringAsFixed(0)}m '
        '焦距(像素)=${focalLengthPx?.toStringAsFixed(1) ?? "-"} '
        'ms=${far.inferenceMs.toStringAsFixed(1)}',
      );
    }
    _farFrameCounter += 1;
    return far;
  }

  int _farFrameCounter = 0;

  /// 按用户设置的 TTC 阈值重新分级（危险 / 注意）。
  TtcResult _applyThreshold(TtcResult result, double threshold) {
    var level = 0;
    if (result.inPath && result.redAllowed && result.ttc < threshold) {
      level = result.ttc < threshold * 0.75 ? 2 : 1;
    }
    return TtcResult(
      ttc: result.ttc,
      vx: result.vx,
      vy: result.vy,
      dwDt: result.dwDt,
      redAllowed: result.redAllowed,
      vw: result.vw,
      isStatic: result.isStatic,
      riskLevel: level,
      inPath: result.inPath,
    );
  }

  RiskSnapshot? get lastSnapshot => _lastSnapshot;

  Future<void> dispose() async {
    await _detector.dispose();
    _ready = false;
  }
}

/// 绘制平滑层：把"原始测量快照"转成"绘制快照"。
///
/// 画面标框（`_DetectionPainter`）与俯视图（`BevView`）都直接读 [RiskSnapshot]，
/// 因此只要在这一层替换几何，**两个视图就同时获得平滑**，而且俯视图的距离/横向偏移
/// 由**同一个**平滑框重算，两边位置永远一致（不会出现"框跟着走、俯视图还在原地"）。
///
/// 只处理本帧确实看到的目标（`isFresh`）：没看到的目标界面本来就不画，
/// 其趋势状态保持不动，下次再看到时按帧间隔决定是继续外推还是重新起头。
class DisplaySmoother {
  DisplaySmoother({
    required this.ipm,
    this.estimator = const MonocularDistanceEstimator(),
    BoxTrendSmoother? filter,
  }) : filter = filter ?? BoxTrendSmoother();

  final BoxTrendSmoother filter;
  final MonocularDistanceEstimator estimator;
  final IpmTransformer ipm;

  /// 平滑强度 0–0.9（0 = 关闭）。
  double get strength => filter.strength;

  set strength(double value) => filter.strength = value;

  bool get enabled => filter.enabled;

  /// 对 [raw] 中每个目标做趋势平滑，并用平滑后的框重算距离与横向偏移。
  RiskSnapshot apply({
    required RiskSnapshot raw,
    required int frameIndex,
    double? focalLengthPx,
    Set<int>? activeTrackIds,
  }) {
    final frameWidth = raw.frameWidth;
    final frameHeight = raw.frameHeight;

    final objects = <TrackedObject>[];
    for (final object in raw.objects) {
      if (!object.isFresh) {
        objects.add(object); // 本帧没看到：保持原样（界面不会绘制它）
        continue;
      }

      final box = filter.smooth(
        trackId: object.id,
        measurement: object.detection,
        frameIndex: frameIndex,
        frameWidth: frameWidth.toDouble(),
        frameHeight: frameHeight.toDouble(),
      );
      final detection = box.toDetection(object.detection);

      final estimate = estimateDistance(
        detection: detection,
        frameWidth: frameWidth,
        frameHeight: frameHeight,
        focalLengthPx: focalLengthPx,
        estimator: estimator,
        ipm: ipm,
      );
      final lateral = estimateLateralOffset(
        centerX: detection.centerX,
        imageWidth: frameWidth.toDouble(),
        focalLengthPx: focalLengthPx,
        distanceM: estimate.meters,
      );

      objects.add(TrackedObject(
        id: object.id,
        detection: detection,
        ttc: object.ttc,
        distance: estimate.meters,
        distanceSource: estimate.source,
        lateralMeters: lateral,
        relativeSpeedMps: object.relativeSpeedMps,
        misses: object.misses,
        smoothed: box.usedTrend,
      ));
    }

    if (activeTrackIds != null) {
      filter.retain(activeTrackIds);
    }

    return RiskSnapshot(
      objects: objects,
      minTtc: raw.minTtc,
      riskLevel: raw.riskLevel,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      inferenceMs: raw.inferenceMs,
      processed: raw.processed,
    );
  }

  void reset() => filter.reset();
}

/// 把 Android 相机图像流的 YUV420 三个平面转换为紧凑 RGB888。
///
/// 移动端相机（Camera2）在 `ImageFormatGroup.yuv420` 下会给出 3 个平面
/// （Y / U / V），各自带 rowStride，且色度平面的像素步长通常为 2，因此这里按
/// 平面分别采样，比"交错 VU"的写法更可靠。
Uint8List yuv420PlanesToRgb({
  required Uint8List yPlane,
  required Uint8List uPlane,
  required Uint8List vPlane,
  required int width,
  required int height,
  required int yRowStride,
  required int uvRowStride,
  required int uvPixelStride,
}) {
  final rgb = Uint8List(width * height * 3);

  for (var y = 0; y < height; y++) {
    final yRow = y * yRowStride;
    final uvRow = (y >> 1) * uvRowStride;
    final rgbRow = y * width * 3;

    for (var x = 0; x < width; x++) {
      final yValue = yPlane[yRow + x];
      final uvIndex = uvRow + (x >> 1) * uvPixelStride;
      final uValue = uvIndex < uPlane.length ? uPlane[uvIndex] : 128;
      final vValue = uvIndex < vPlane.length ? vPlane[uvIndex] : 128;

      final u = uValue - 128;
      final v = vValue - 128;
      final yScaled = (yValue - 16) * 1.164;

      final r = (yScaled + 1.596 * v).round();
      final g = (yScaled - 0.392 * u - 0.813 * v).round();
      final b = (yScaled + 2.017 * u).round();

      final offset = rgbRow + x * 3;
      rgb[offset] = r < 0 ? 0 : (r > 255 ? 255 : r);
      rgb[offset + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
      rgb[offset + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }
  return rgb;
}
