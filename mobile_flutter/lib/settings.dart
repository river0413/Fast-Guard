/// 移动端设置（端上推理版）——持久化到 SharedPreferences。
///
/// 与 PC 端"阈值设置"的差异说明：
/// * PC 端的「边缘强度阈值」服务于**预处理图像增强**分支，移动端已按设计要求
///   去掉该分支，因此这里不再有该项；
/// * 端上推理新增「TTC 告警阈值」，用于调节前向碰撞告警的灵敏度。
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'core/box_smoother.dart';
import 'ui/bev_view_mode.dart';

/// 摄像头可选序号（手机端 0 = 后置主摄，1 = 前置）。
const List<int> kCameraChoices = <int>[0, 1];

/// 推理图片大小候选（必须是 32 的倍数；模型为动态输入，可运行时切换）。
const List<int> kInferenceSizeChoices = <int>[320, 416, 512, 640];

/// 远距监测（长焦）距离阈值候选（米）。
const List<double> kFarDistanceChoices = <double>[20, 30, 40, 60, 80];

class AppSettings {
  AppSettings({
    this.cameraIndex = 0,
    this.confidence = 0.35,
    this.iouThreshold = 0.45,
    this.ttcThreshold = 2.0,
    this.inferenceSize = 320,
    this.processEveryNthFrame = 3,
    this.showAllClasses = false,
    this.showDebugOverlay = false,
    this.showBev = true,
    this.bevViewMode = BevViewMode.rectangular,
    this.boxSmoothing = true,
    this.boxSmoothingStrength = BoxTrendSmoother.kDefaultStrength,
    this.useInt8Model = false,
    this.farTargetEnabled = false,
    this.farDistanceThresholdM = 40.0,  });

  /// 摄像头序号（映射到 camera 插件的 CameraDescription 列表下标）。
  int cameraIndex;

  /// 置信度阈值（对应原「低置信度阈值」）。
  double confidence;

  /// NMS 的 IoU 阈值。
  double iouThreshold;

  /// TTC 告警阈值（秒）：低于该值判定为注意/危险。
  double ttcThreshold;

  /// 推理图片大小（imgsz）。
  int inferenceSize;

  /// 每处理 N 帧推理一次（节流，保证预览流畅）。
  int processEveryNthFrame;

  /// 是否显示全部 80 类（默认只显示交通参与者）。
  bool showAllClasses;

  /// 是否显示耗时等调试信息。
  bool showDebugOverlay;

  /// 是否显示俯视图（BEV / IPM 视图）。
  bool showBev;

  /// 俯视图形态：方形（笛卡尔网格）/ 扇形（雷达式极坐标）。
  BevViewMode bevViewMode;

  /// 是否对检测框做趋势平滑（画面标框与俯视图同时生效）。
  bool boxSmoothing;

  /// 平滑强度 0–0.9：越大越依赖前两帧趋势的外推；0 等价于关闭。
  double boxSmoothingStrength;

  /// 是否使用 INT8 量化模型（体积更小；检测头保持 FP32）。
  ///
  /// 默认 FP32：INT8 的量化配方与校准集强相关，需在真机上确认后再启用
  /// （见 `inference/model_assets.dart` 里的说明与 `tools/export_int8_onnx.py`）。
  bool useInt8Model;

  /// 是否开启远距监测（后置长焦并发流）。默认关闭：并发双流依赖设备 HAL 支持，
  /// 且长焦只在"想看更远处"时才有必要（见 `pipeline/far_target_engine.dart`）。
  bool farTargetEnabled;

  /// 远距监测的距离阈值（米）：只关心比它更远的目标。远距目标**只标距离**。
  double farDistanceThresholdM;

  static const String _keyCamera = 'camera_index';
  static const String _keyConfidence = 'confidence';
  static const String _keyIou = 'iou';
  static const String _keyTtc = 'ttc_threshold';
  static const String _keySize = 'inference_size';
  static const String _keyEvery = 'process_every_nth';
  static const String _keyAllClasses = 'show_all_classes';
  static const String _keyDebug = 'show_debug';
  static const String _keyBev = 'show_bev';
  static const String _keyBevMode = 'bev_view_mode';
  static const String _keySmoothing = 'box_smoothing';
  static const String _keySmoothingStrength = 'box_smoothing_strength';
  static const String _keyInt8 = 'use_int8_model';
  static const String _keyFarTarget = 'far_target_enabled';
  static const String _keyFarDistance = 'far_distance_threshold_m';

  /// 从持久化存储读取（缺失或非法时回退默认值）。
  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final settings = AppSettings();
    settings.cameraIndex = prefs.getInt(_keyCamera) ?? settings.cameraIndex;
    settings.confidence = prefs.getDouble(_keyConfidence) ?? settings.confidence;
    settings.iouThreshold = prefs.getDouble(_keyIou) ?? settings.iouThreshold;
    settings.ttcThreshold = prefs.getDouble(_keyTtc) ?? settings.ttcThreshold;
    settings.inferenceSize = prefs.getInt(_keySize) ?? settings.inferenceSize;
    settings.processEveryNthFrame = prefs.getInt(_keyEvery) ?? settings.processEveryNthFrame;
    settings.showAllClasses = prefs.getBool(_keyAllClasses) ?? settings.showAllClasses;
    settings.showDebugOverlay = prefs.getBool(_keyDebug) ?? settings.showDebugOverlay;
    settings.showBev = prefs.getBool(_keyBev) ?? settings.showBev;
    settings.bevViewMode = BevViewMode.fromName(prefs.getString(_keyBevMode));
    settings.boxSmoothing = prefs.getBool(_keySmoothing) ?? settings.boxSmoothing;
    settings.boxSmoothingStrength =
        prefs.getDouble(_keySmoothingStrength) ?? settings.boxSmoothingStrength;
    settings.useInt8Model = prefs.getBool(_keyInt8) ?? settings.useInt8Model;
    settings.farTargetEnabled = prefs.getBool(_keyFarTarget) ?? settings.farTargetEnabled;
    settings.farDistanceThresholdM =
        prefs.getDouble(_keyFarDistance) ?? settings.farDistanceThresholdM;
    return settings.normalized();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyCamera, cameraIndex);
    await prefs.setDouble(_keyConfidence, confidence);
    await prefs.setDouble(_keyIou, iouThreshold);
    await prefs.setDouble(_keyTtc, ttcThreshold);
    await prefs.setInt(_keySize, inferenceSize);
    await prefs.setInt(_keyEvery, processEveryNthFrame);
    await prefs.setBool(_keyAllClasses, showAllClasses);
    await prefs.setBool(_keyDebug, showDebugOverlay);
    await prefs.setBool(_keyBev, showBev);
    await prefs.setString(_keyBevMode, bevViewMode.name);
    await prefs.setBool(_keySmoothing, boxSmoothing);
    await prefs.setDouble(_keySmoothingStrength, boxSmoothingStrength);
    await prefs.setBool(_keyInt8, useInt8Model);
    await prefs.setBool(_keyFarTarget, farTargetEnabled);
    await prefs.setDouble(_keyFarDistance, farDistanceThresholdM);
  }

  /// 越界值回落到合法范围（对应 PC 端脚本里的参数规整）。
  AppSettings normalized() {
    confidence = confidence.clamp(0.10, 0.95);
    iouThreshold = iouThreshold.clamp(0.10, 0.90);
    ttcThreshold = ttcThreshold.clamp(0.5, 5.0);
    boxSmoothingStrength = boxSmoothingStrength.clamp(0.0, BoxTrendSmoother.kMaxStrength);
    farDistanceThresholdM = farDistanceThresholdM.clamp(10.0, 120.0);
    if (!kFarDistanceChoices.any((choice) => (choice - farDistanceThresholdM).abs() < 1e-6)) {
      // 归到最近的候选档位：设置栏是分段按钮，必须能选中一档
      var nearest = kFarDistanceChoices.first;
      for (final choice in kFarDistanceChoices) {
        if ((choice - farDistanceThresholdM).abs() < (nearest - farDistanceThresholdM).abs()) {
          nearest = choice;
        }
      }
      farDistanceThresholdM = nearest;
    }
    if (!kInferenceSizeChoices.contains(inferenceSize)) {
      inferenceSize = 320;
    }
    processEveryNthFrame = processEveryNthFrame.clamp(1, 10);
    if (cameraIndex < 0) {
      cameraIndex = 0;
    }
    return this;
  }

  AppSettings copy() => AppSettings(
        cameraIndex: cameraIndex,
        confidence: confidence,
        iouThreshold: iouThreshold,
        ttcThreshold: ttcThreshold,
        inferenceSize: inferenceSize,
        processEveryNthFrame: processEveryNthFrame,
        showAllClasses: showAllClasses,
        showDebugOverlay: showDebugOverlay,
        showBev: showBev,
        bevViewMode: bevViewMode,
        boxSmoothing: boxSmoothing,
        boxSmoothingStrength: boxSmoothingStrength,
        useInt8Model: useInt8Model,
        farTargetEnabled: farTargetEnabled,
        farDistanceThresholdM: farDistanceThresholdM,
      );

  /// 供界面显示的一行摘要。
  String get summary => '摄像头 $cameraIndex · ${inferenceSize}px · 阈值 '
      '${confidence.toStringAsFixed(2)} / TTC ${ttcThreshold.toStringAsFixed(1)}s · '
      '平滑 ${boxSmoothing ? boxSmoothingStrength.toStringAsFixed(2) : '关'} · '
      '${useInt8Model ? 'INT8' : 'FP32'} · '
      '俯视${bevViewMode == BevViewMode.sector ? '扇形' : '方形'}'
      '${farTargetEnabled ? ' · 远距 ${farDistanceThresholdM.toStringAsFixed(0)}m+' : ''}';

  void copyFrom(AppSettings other) {
    cameraIndex = other.cameraIndex;
    confidence = other.confidence;
    iouThreshold = other.iouThreshold;
    ttcThreshold = other.ttcThreshold;
    inferenceSize = other.inferenceSize;
    processEveryNthFrame = other.processEveryNthFrame;
    showAllClasses = other.showAllClasses;
    showDebugOverlay = other.showDebugOverlay;
    showBev = other.showBev;
    bevViewMode = other.bevViewMode;
    boxSmoothing = other.boxSmoothing;
    boxSmoothingStrength = other.boxSmoothingStrength;
    useInt8Model = other.useInt8Model;
    farTargetEnabled = other.farTargetEnabled;
    farDistanceThresholdM = other.farDistanceThresholdM;
  }

  @override
  String toString() => 'AppSettings($summary)';
}
