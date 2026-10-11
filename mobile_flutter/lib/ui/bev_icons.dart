/// 俯视图（BEV）里表示**载具种类**的矢量标识。
///
/// 为什么不引 SVG：`flutter_svg` 会带来额外依赖与资产文件（图标集还牵扯授权），
/// 而这里只需要几个简单字形。直接用 [Path] 画，零新增依赖，且能在 `flutter test`
/// 里断言"类别 → 标识"的映射（见 `test/bev_view_test.dart`）。
///
/// 字形一律在归一化坐标（0..1 × 0..1）里定义，再按目标矩形缩放，
/// 因此方形布局与扇形布局可以共用同一套图标。
library;

import 'package:flutter/material.dart';

/// 载具种类标识。
enum BevIconKind {
  person,
  bicycle,
  motorcycle,
  car,
  bus,
  truck,
  unknown,
}

/// COCO 类别 → 标识。未标定的类别（红绿灯/标志牌等）用 [BevIconKind.unknown]。
BevIconKind bevIconKindFor(int classId) {
  switch (classId) {
    case 0:
      return BevIconKind.person;
    case 1:
      return BevIconKind.bicycle;
    case 3:
      return BevIconKind.motorcycle;
    case 2:
      return BevIconKind.car;
    case 5:
      return BevIconKind.bus;
    case 7:
      return BevIconKind.truck;
    default:
      return BevIconKind.unknown;
  }
}

/// 标识的中文名（用于自检与测试断言）。
String bevIconKindLabel(BevIconKind kind) {
  switch (kind) {
    case BevIconKind.person:
      return '行人';
    case BevIconKind.bicycle:
      return '自行车';
    case BevIconKind.motorcycle:
      return '摩托车';
    case BevIconKind.car:
      return '轿车';
    case BevIconKind.bus:
      return '公交车';
    case BevIconKind.truck:
      return '卡车';
    case BevIconKind.unknown:
      return '未知';
  }
}

/// 在 [box] 内绘制 [kind] 标识（描边，颜色与线宽由调用方给定）。
///
/// [box] 已经是"标识可用区域"（调用方需自行留边），本函数不会越界绘制。
void paintBevIcon(
  Canvas canvas,
  Rect box,
  BevIconKind kind, {
  required Color color,
  double strokeWidth = 1.4,
}) {
  if (box.width <= 0 || box.height <= 0) {
    return;
  }
  final paint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  // 归一化坐标 → 画布坐标
  Offset at(double x, double y) =>
      Offset(box.left + x * box.width, box.top + y * box.height);

  Path poly(List<List<double>> points) {
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point = at(points[i][0], points[i][1]);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    return path;
  }

  switch (kind) {
    case BevIconKind.person:
      // 头 + 躯干 + 双臂 + 双腿
      canvas.drawCircle(at(0.5, 0.16), box.shortestSide * 0.14, paint);
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.5, 0.34],
          <double>[0.5, 0.70],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.16, 0.46],
          <double>[0.84, 0.46],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.5, 0.70],
          <double>[0.28, 0.98],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.5, 0.70],
          <double>[0.72, 0.98],
        ]),
        paint,
      );
    case BevIconKind.bicycle:
      // 两个轮子 + 三角车架 + 车把
      canvas.drawCircle(at(0.20, 0.74), box.shortestSide * 0.21, paint);
      canvas.drawCircle(at(0.80, 0.74), box.shortestSide * 0.21, paint);
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.20, 0.74],
          <double>[0.46, 0.42],
          <double>[0.80, 0.74],
          <double>[0.20, 0.74],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.46, 0.42],
          <double>[0.36, 0.26],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.72, 0.30],
          <double>[0.90, 0.30],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.80, 0.74],
          <double>[0.81, 0.30],
        ]),
        paint,
      );
    case BevIconKind.motorcycle:
      // 两个轮子 + 车身 + 车把（比自行车更粗）
      canvas.drawCircle(at(0.19, 0.76), box.shortestSide * 0.20, paint);
      canvas.drawCircle(at(0.81, 0.76), box.shortestSide * 0.20, paint);
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.24, 0.62],
          <double>[0.52, 0.48],
          <double>[0.80, 0.62],
          <double>[0.66, 0.80],
          <double>[0.36, 0.80],
          <double>[0.24, 0.62],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.62, 0.42],
          <double>[0.88, 0.28],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.52, 0.48],
          <double>[0.40, 0.26],
        ]),
        paint,
      );
    case BevIconKind.car:
      // 俯视车身：前后收窄的车身 + 前挡风玻璃
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.50, 0.04],
          <double>[0.88, 0.26],
          <double>[0.94, 0.74],
          <double>[0.78, 0.96],
          <double>[0.22, 0.96],
          <double>[0.06, 0.74],
          <double>[0.12, 0.26],
          <double>[0.50, 0.04],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.16, 0.42],
          <double>[0.84, 0.42],
        ]),
        paint,
      );
    case BevIconKind.bus:
      // 俯视客车：长车身 + 前风挡 + 轮拱
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromPoints(at(0.10, 0.06), at(0.90, 0.94)),
          Radius.circular(box.shortestSide * 0.14),
        ),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.14, 0.34],
          <double>[0.86, 0.34],
        ]),
        paint,
      );
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.14, 0.72],
          <double>[0.86, 0.72],
        ]),
        paint,
      );
    case BevIconKind.truck:
      // 俯视货车：驾驶室 + 货箱
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromPoints(at(0.08, 0.20), at(0.36, 0.80)),
          Radius.circular(box.shortestSide * 0.08),
        ),
        paint,
      );
      canvas.drawRect(Rect.fromPoints(at(0.42, 0.08), at(0.92, 0.92)), paint);
      canvas.drawPath(
        poly(<List<double>>[
          <double>[0.42, 0.50],
          <double>[0.92, 0.50],
        ]),
        paint,
      );
    case BevIconKind.unknown:
      canvas.drawCircle(at(0.5, 0.5), box.shortestSide * 0.32, paint);
  }
}
