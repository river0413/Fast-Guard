/// 读取手机相机的真实光学参数（焦距 / 传感器尺寸 / 35mm 等效焦距）。
///
/// Flutter 的 camera 插件不提供这些数据，因此通过平台通道向 Android 的
/// CameraCharacteristics 查询（实现见 `android/app/src/main/kotlin/.../MainActivity.kt`）。
///
/// 关键量是 **焦距(像素)**，用于针孔测距：
///   距离(米) = 真实尺寸(米) × 焦距(像素) / 目标像素尺寸
library;

import 'package:flutter/services.dart';

/// 相机光学参数。
class CameraOptics {
  const CameraOptics({
    required this.cameraId,
    this.focalLengthsMm = const <double>[],
    this.sensorWidthMm,
    this.sensorHeightMm,
    this.apertures = const <double>[],
    this.sensorOrientation,
    this.cropFactor,
    this.focalLength35mmEq,
  });

  final String cameraId;

  /// 物理焦距候选值（毫米），一般取第一个。
  final List<double> focalLengthsMm;
  final double? sensorWidthMm;
  final double? sensorHeightMm;
  final List<double> apertures;
  final int? sensorOrientation;

  /// 等效系数 = 全画幅对角线 / 传感器对角线。
  final double? cropFactor;

  /// 35mm 等效焦距（毫米）。
  final double? focalLength35mmEq;

  /// 全画幅宽度（36mm），用于把等效焦距换算成像素焦距。
  static const double fullFrameWidthMm = 36.0;

  /// 是否具备测距所需的全部信息。
  bool get canMeasureDistance => focalLength35mmEq != null && focalLength35mmEq! > 0;

  /// 焦距（像素）：`focal35mmEq / 36mm × 图像宽度`。
  ///
  /// 用 35mm 等效焦距换算，可以避开"传感器方向 / 图像旋转"的对应问题。
  double? focalLengthPixels(int imageWidth) {
    final equivalent = focalLength35mmEq;
    if (equivalent == null || equivalent <= 0 || imageWidth <= 0) {
      return null;
    }
    return equivalent / fullFrameWidthMm * imageWidth;
  }

  factory CameraOptics.fromMap(Map<dynamic, dynamic> map) {
    List<double> toDoubleList(dynamic value) {
      if (value is List) {
        return value.whereType<num>().map((item) => item.toDouble()).toList();
      }
      return const <double>[];
    }

    return CameraOptics(
      cameraId: '${map['id'] ?? ''}',
      focalLengthsMm: toDoubleList(map['focalLengthsMm']),
      sensorWidthMm: (map['sensorWidthMm'] as num?)?.toDouble(),
      sensorHeightMm: (map['sensorHeightMm'] as num?)?.toDouble(),
      apertures: toDoubleList(map['apertures']),
      sensorOrientation: (map['sensorOrientation'] as num?)?.toInt(),
      cropFactor: (map['cropFactor'] as num?)?.toDouble(),
      focalLength35mmEq: (map['focalLength35mmEq'] as num?)?.toDouble(),
    );
  }

  /// 便于在设置栏中展示 / 日志排查。
  String describe() {
    final focal = focalLengthsMm.isNotEmpty
        ? focalLengthsMm.map((v) => v.toStringAsFixed(2)).join('/')
        : '未知';
    final sensor = (sensorWidthMm != null && sensorHeightMm != null)
        ? '${sensorWidthMm!.toStringAsFixed(2)}×${sensorHeightMm!.toStringAsFixed(2)}mm'
        : '未知';
    final equivalent = focalLength35mmEq != null
        ? '${focalLength35mmEq!.toStringAsFixed(1)}mm(35mm等效)'
        : '未知';
    return '相机 $cameraId · 物理焦距 $focal mm · 传感器 $sensor · $equivalent';
  }

  @override
  String toString() => 'CameraOptics(${describe()})';
}

/// 平台通道封装。
class CameraInfoChannel {
  CameraInfoChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('fastguard/camera_info');

  final MethodChannel _channel;

  /// 查询指定相机的光学参数；失败或平台不支持时返回 null。
  Future<CameraOptics?> getCameraInfo(String? cameraId) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getCameraInfo',
        <String, dynamic>{'cameraId': cameraId},
      );
      if (result == null) {
        return null;
      }
      return CameraOptics.fromMap(result);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null; // 例如在桌面/测试环境运行
    }
  }

  /// 列出可用相机 id。
  Future<List<String>> listCameras() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listCameras');
      return result?.map((item) => '$item').toList() ?? const <String>[];
    } on PlatformException {
      return const <String>[];
    } on MissingPluginException {
      return const <String>[];
    }
  }
}
