/// 后置**长焦**镜头的平台通道：相机枚举 + 长焦画面帧流。
///
/// Flutter 的 `camera` 插件一次只能开一路图像流，所以"主摄 + 长焦同时取流"
/// 必须走原生 Camera2 并发会话（实现见
/// `android/app/src/main/kotlin/com/fastguard/fastguard_mobile/TelephotoStream.kt`）。
///
/// 三件事分开：
/// * [listBackCameras]：列出后置相机的光学信息（用于挑出长焦，并判断是否支持并发）；
/// * [pickTelephotoCamera]：**纯函数**，从相机列表里选出长焦（便于单测）；
/// * [frames]：长焦画面帧流（YUV420 三平面，与主摄回调同构，可复用
///   `yuv420PlanesToRgb`）。
///
/// 任何一步失败都只会让**远距模式不可用**（[available] 为 false + [unsupportedReason]），
/// 不会影响主摄链路。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/camera_optics.dart';
import '../pipeline/inference_engine.dart' show yuv420PlanesToRgb;

/// 原生返回的后置相机描述。
class BackCameraInfo {
  const BackCameraInfo({
    required this.id,
    required this.optics,
    this.isLogicalMultiCamera = false,
    this.concurrentSupported = false,
  });

  final String id;
  final CameraOptics optics;

  /// 是否为**逻辑多摄**（Android 的 multi-camera）：其物理子摄会各有自己的 id。
  final bool isLogicalMultiCamera;

  /// 与"当前主摄"是否支持并发流（由 `CameraManager.getConcurrentCameraIds()` 判定）。
  final bool concurrentSupported;

  factory BackCameraInfo.fromMap(Map<dynamic, dynamic> map, {required String mainCameraId}) {
    final id = '${map['id'] ?? ''}';
    return BackCameraInfo(
      id: id,
      optics: CameraOptics.fromMap(<dynamic, dynamic>{
        'id': id,
        'focalLengthsMm': map['focalLengthsMm'],
        'sensorWidthMm': map['sensorWidthMm'],
        'sensorHeightMm': map['sensorHeightMm'],
        'apertures': map['apertures'],
        'sensorOrientation': map['sensorOrientation'],
        'cropFactor': map['cropFactor'],
        'focalLength35mmEq': map['focalLength35mmEq'],
      }),
      isLogicalMultiCamera: map['isLogicalMultiCamera'] == true,
      concurrentSupported: map['concurrentSupported'] == true,
    );
  }

  @override
  String toString() => 'BackCameraInfo($id${isLogicalMultiCamera ? ', 逻辑多摄' : ''}'
      '${concurrentSupported ? ', 支持并发' : ''}, ${optics.describe()})';
}

/// 从后置相机列表里挑**长焦**。
///
/// 规则（纯函数，便于单测）：
/// 1. 排除 [mainCameraId]（那是主摄，正在被 `camera` 插件占用）；
/// 2. 排除物理不可用/无 35mm 等效焦距的项（拿不到焦距就没法测距）；
/// 3. 若有 [preferConcurrent]（默认 true），只考虑 `concurrentSupported` 的项；
/// 4. 取 35mm 等效焦距**最大**者；并列时优先非逻辑多摄（物理子摄画面更干净）。
///
/// 找不到任何候选时返回 null（→ 远距模式不可用）。
BackCameraInfo? pickTelephotoCamera(
  List<BackCameraInfo> cameras, {
  required String? mainCameraId,
  bool preferConcurrent = true,
}) {
  List<BackCameraInfo> candidates = cameras
      .where((camera) => camera.id != mainCameraId)
      .where((camera) => camera.optics.canMeasureDistance)
      .toList();
  if (candidates.isEmpty) {
    return null;
  }
  if (preferConcurrent) {
    final concurrent =
        candidates.where((camera) => camera.concurrentSupported).toList();
    if (concurrent.isEmpty) {
      return null; // 没有支持并发流的长焦：远距模式不可用（不勉强分时切换）
    }
    candidates = concurrent;
  }
  candidates.sort((a, b) {
    final byFocal = (b.optics.focalLength35mmEq ?? 0).compareTo(a.optics.focalLength35mmEq ?? 0);
    if (byFocal != 0) {
      return byFocal;
    }
    return (a.isLogicalMultiCamera ? 1 : 0).compareTo(b.isLogicalMultiCamera ? 1 : 0);
  });
  return candidates.first;
}

/// 长焦平台通道封装。
class TelephotoChannel {
  TelephotoChannel({MethodChannel? methodChannel, EventChannel? eventChannel})
      : _methods = methodChannel ?? const MethodChannel('fastguard/telephoto'),
        _events = eventChannel ?? const EventChannel('fastguard/telephoto_stream');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<CameraFrame>? _frames;

  /// 远距模式是否可用（最近一次 [open] 的结果）。
  bool _available = false;
  bool get available => _available;

  /// 不可用时的原因（面向用户的短句）。
  String? _unsupportedReason;
  String? get unsupportedReason => _unsupportedReason;

  /// 已选中的长焦相机（成功打开后非空）。
  BackCameraInfo? _camera;
  BackCameraInfo? get camera => _camera;

  /// 列出可用**后置**相机的光学信息；平台不支持或无权限时返回空列表。
  Future<List<BackCameraInfo>> listBackCameras({String? mainCameraId}) async {
    try {
      final result = await _methods.invokeMethod<List<dynamic>>('listBackCameras');
      if (result == null) {
        debugPrint('[FastGuard] 长焦枚举：原生返回 null（远距模式不可用）');
        return const <BackCameraInfo>[];
      }
      final cameras = result
          .whereType<Map<dynamic, dynamic>>()
          .map((map) => BackCameraInfo.fromMap(map, mainCameraId: mainCameraId ?? ''))
          .toList();
      // 不做 kDebugMode 判断：release 包也要能在 logcat 里看清"设备到底有几个后摄/哪个能并发"
      debugPrint(
        '[FastGuard] 长焦枚举：后置相机 ${cameras.length} 个'
        '${cameras.isEmpty ? '' : ' → ${cameras.map((camera) => '${camera.id}'
            '(${camera.optics.focalLength35mmEq?.toStringAsFixed(1) ?? "-"}mm'
            '${camera.concurrentSupported ? ',可并发' : ''})').join(' / ')}'}',
      );
      return cameras;
    } on PlatformException catch (error) {
      // 之前这里是静默返回空列表，导致真机上"远距开关自动关闭"却查不出原因
      debugPrint(
        '[FastGuard] 长焦枚举失败：${error.code} ${error.message ?? ''}'
        '${error.details == null ? '' : ' ${error.details}'}',
      );
      return const <BackCameraInfo>[];
    } on MissingPluginException {
      debugPrint('[FastGuard] 长焦枚举：当前平台没有 fastguard/telephoto 通道');
      return const <BackCameraInfo>[]; // 桌面/测试环境
    }
  }

  /// 挑选并**打开**长焦流。
  ///
  /// 选择逻辑留在 Dart 侧（[pickTelephotoCamera]，可单测），原生只负责按 id 开流。
  /// 成功时 [available] 为 true；失败时返回 false 并给出 [unsupportedReason]
  /// （区分"没有长焦"与"设备不支持并发"），调用方据此在设置栏提示并关闭远距开关。
  Future<bool> open({required String? mainCameraId}) async {
    _available = false;
    _camera = null;
    _unsupportedReason = null;

    final cameras = await listBackCameras(mainCameraId: mainCameraId);
    if (cameras.isEmpty) {
      _unsupportedReason = '未取到后置相机信息（远距模式不可用）';
      debugPrint('[FastGuard] 远距模式不可用：$unsupportedReason');
      return false;
    }
    final picked = pickTelephotoCamera(cameras, mainCameraId: mainCameraId);
    if (picked == null) {
      final others = cameras.where((camera) => camera.id != mainCameraId).toList();
      _unsupportedReason = others.isEmpty
          ? '未找到后置长焦镜头（远距模式不可用）'
          : '后置镜头不支持与主摄并发取流（远距模式不可用）';
      debugPrint(
        '[FastGuard] 远距模式不可用：$unsupportedReason'
        '（主摄=$mainCameraId，其它后摄=${others.map((camera) => camera.id).join("/")}，'
        '可并发=${others.where((camera) => camera.concurrentSupported).map((c) => c.id).join("/")}）',
      );
      return false;
    }

    try {
      final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
        'startTelephoto',
        <String, dynamic>{'cameraId': picked.id},
      );
      if (result == null || result['ok'] != true) {
        _unsupportedReason = '${result?['reason'] ?? '长焦启动失败'}';
        debugPrint('[FastGuard] 远距模式不可用：$unsupportedReason');
        return false;
      }
      _camera = picked;
      _available = true;
      debugPrint('[FastGuard] 长焦已打开：相机 ${picked.id}，出图 ${result['size']}');
      return true;
    } on PlatformException catch (error) {
      _unsupportedReason = '长焦启动失败：${error.message ?? error.code}';
      debugPrint('[FastGuard] 远距模式不可用：$unsupportedReason');
      return false;
    } on MissingPluginException {
      _unsupportedReason = '当前平台不支持长焦并发流';
      debugPrint('[FastGuard] 远距模式不可用：$unsupportedReason');
      return false;
    }
  }

  /// 关闭长焦流（幂等）。
  Future<void> close() async {
    final wasAvailable = _available;
    _available = false;
    _camera = null;
    try {
      await _methods.invokeMethod<void>('stopTelephoto');
    } on PlatformException {
      // 关闭失败无需上报：下次 open 会重新建立
    } on MissingPluginException {
      // 平台不支持：忽略
    }
    if (wasAvailable) {
      debugPrint('[FastGuard] 长焦已关闭');
    }
  }

  /// 长焦画面帧流（惰性建立，只广播一次）。
  Stream<CameraFrame> get frames => _frames ??= _events
      .receiveBroadcastStream()
      .where((event) => event is Map)
      .map((event) => CameraFrame.fromMap(event as Map<dynamic, dynamic>))
      .where((frame) => frame.isValid)
      .asBroadcastStream();
}

/// 一帧图像平面（与 `camera` 插件的 `Plane` 同构）。
class FramePlane {
  const FramePlane({required this.bytes, required this.bytesPerRow, this.bytesPerPixel});

  final Uint8List bytes;
  final int bytesPerRow;
  final int? bytesPerPixel;
}

/// 长焦的一帧画面（YUV420 三平面）。
class CameraFrame {
  const CameraFrame({
    required this.width,
    required this.height,
    required this.planes,
    this.timestampNs,
  });

  final int width;
  final int height;
  final List<FramePlane> planes;
  final int? timestampNs;

  /// YUV420 需要 Y/U/V 三个平面才可转换。
  bool get isValid => planes.length >= 3 && width > 0 && height > 0;

  /// YUV420 → RGB888（复用主摄链路的转换实现，保证两路颜色处理一致）。
  Uint8List toRgb() => yuv420PlanesToRgb(
        yPlane: planes[0].bytes,
        uPlane: planes[1].bytes,
        vPlane: planes[2].bytes,
        width: width,
        height: height,
        yRowStride: planes[0].bytesPerRow,
        uvRowStride: planes[1].bytesPerRow,
        uvPixelStride: planes[1].bytesPerPixel ?? 2,
      );

  factory CameraFrame.fromMap(Map<dynamic, dynamic> map) {
    final planes = <FramePlane>[];
    final rawPlanes = map['planes'];
    if (rawPlanes is List) {
      for (final plane in rawPlanes) {
        if (plane is Map) {
          planes.add(FramePlane(
            bytes: plane['bytes'] as Uint8List? ?? Uint8List(0),
            bytesPerRow: (plane['bytesPerRow'] as num?)?.toInt() ?? 0,
            bytesPerPixel: (plane['bytesPerPixel'] as num?)?.toInt(),
          ));
        }
      }
    }
    return CameraFrame(
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      planes: planes,
      timestampNs: (map['timestampNs'] as num?)?.toInt(),
    );
  }
}
