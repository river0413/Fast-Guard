/// 主摄**中心裁切**（数字变焦）：长焦拿不到数据时的远距监测回退路径。
///
/// 为什么需要它：不少国产 ROM（例如 MEIZU 21 Pro 的 Flyme）对第三方应用**只暴露主摄**，
/// 长焦/超广角被 HAL 隐藏（`getCameraIdList()` 里根本没有它们），
/// 于是"主摄 + 长焦并发双流"在这类机型上不可能实现。
/// 此时把主摄画面的中央区域裁出来交给同一个检测器，等效于数字变焦，
/// 仍能建立"对远距离目标的监测"（只是分辨率不如真长焦）。
///
/// **不做插值**：裁切只是取出子矩形（同一像素密度），
/// 后续 letterbox 到 320/416 时自然完成放大，避免二次插值损失。
/// 因此等效焦距可直接按像素宽度比换算：
///
///     裁切焦距(像素) = 主摄焦距(像素) × 全宽 / 裁切宽
///
/// 横向偏移公式在这个换算下**天然不变**
/// （`(u′-cx′)/f′ = (u-cx)/f`），所以远距目标可以直接用裁切坐标算横向位置。
library;

import 'dart:typed_data';

/// 默认数字变焦倍数（中心裁切 1/3 边长 ≈ 3× 视觉放大）。
const double kFarCropZoom = 3.0;

/// 一次中心裁切的结果。
class CroppedFrame {
  const CroppedFrame({
    required this.rgb,
    required this.width,
    required this.height,
    required this.zoom,
  });

  /// 裁切后的紧凑 RGB888 数据（长度 = width × height × 3）。
  final Uint8List rgb;
  final int width;
  final int height;

  /// **实际**放大倍数 = 全宽 / 裁切宽。
  ///
  /// 与请求的倍数可能略有差异（裁切宽必须是整数），因此测距必须用这个实际值，
  /// 否则距离会有百分之几的系统偏差。
  final double zoom;
}

/// 取出 [rgb] 的中央区域（按 [zoom] 倍数字变焦）。
///
/// [zoom] ≤ 1 或参数非法时返回整帧（`zoom = 1`），调用方无需特判。
CroppedFrame cropCenterRgb({
  required Uint8List rgb,
  required int width,
  required int height,
  double zoom = kFarCropZoom,
}) {
  if (width <= 0 || height <= 0 || zoom <= 1.0) {
    return CroppedFrame(rgb: rgb, width: width, height: height, zoom: 1.0);
  }
  if (rgb.length < width * height * 3) {
    throw ArgumentError('RGB 数据长度不足：${rgb.length} < ${width * height * 3}');
  }

  var cropWidth = (width / zoom).round();
  var cropHeight = (height / zoom).round();
  // 至少保留 1 像素，避免极端参数下出现 0 尺寸
  cropWidth = cropWidth.clamp(1, width);
  cropHeight = cropHeight.clamp(1, height);
  if (cropWidth == width && cropHeight == height) {
    return CroppedFrame(rgb: rgb, width: width, height: height, zoom: 1.0);
  }

  final left = (width - cropWidth) ~/ 2;
  final top = (height - cropHeight) ~/ 2;
  final output = Uint8List(cropWidth * cropHeight * 3);

  for (var row = 0; row < cropHeight; row++) {
    final sourceStart = ((top + row) * width + left) * 3;
    final targetStart = row * cropWidth * 3;
    // 逐行整块拷贝（同一像素密度，不需要插值）
    output.setRange(targetStart, targetStart + cropWidth * 3, rgb, sourceStart);
  }

  return CroppedFrame(
    rgb: output,
    width: cropWidth,
    height: cropHeight,
    zoom: width / cropWidth,
  );
}
