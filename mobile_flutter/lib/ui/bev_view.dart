/// 俯视图（BEV / IPM 视图）：以本车为中心，把已估出位置的目标画在鸟瞰平面上。
///
/// **为什么不做经典 IPM 反投影**：经典做法要求预先知道相机安装高度与俯仰角
/// （`core/ipm.py` 里的默认值是 1.4 m / 8°），但手机在车内的实际摆放姿态无法预知。
/// 现在有了**真实焦距**，横向位置可以直接由针孔关系得到：
///
///     纵向 Y = 距离（由"真实尺寸 ÷ 框尺寸 × 焦距"估出）
///     横向 X = (u - cx) / f × Y
///
/// 因此本视图不需要猜测相机安装姿态，只需假设目标位于地面附近、且手机横屏正对前方。
///
/// 目标位置取自 [TrackedObject.distance] / [TrackedObject.lateralMeters]，而这两个值由端上
/// 管线里**同一个平滑框**重算（见 `DisplaySmoother`）：开启「标框平滑」后，俯视图与画面
/// 标框**一起**变平滑，且两者位置永远自洽（不会出现"框在动、俯视图不动"）。
library;

import 'package:flutter/material.dart';

import '../pipeline/inference_engine.dart';

/// 俯视图叠加层。
class BevView extends StatelessWidget {
  const BevView({
    super.key,
    required this.snapshot,
    this.maxMeters = 40.0,
    this.widthMeters = 16.0,
  });

  final RiskSnapshot? snapshot;

  /// 纵向显示范围（米）。
  final double maxMeters;

  /// 横向显示范围（米）。
  final double widthMeters;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        color: const Color(0xCC09090B),
        child: CustomPaint(
          painter: _BevPainter(
            snapshot: snapshot,
            maxMeters: maxMeters,
            widthMeters: widthMeters,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }
}

class _BevPainter extends CustomPainter {
  _BevPainter({
    required this.snapshot,
    required this.maxMeters,
    required this.widthMeters,
  });

  final RiskSnapshot? snapshot;
  final double maxMeters;
  final double widthMeters;

  /// 本车宽度（米），用于画自车轮廓。
  static const double egoWidthM = 1.9;

  /// 安全通道半宽（米），与 PC 端 `envelope_margin` 一致的量级。
  static const double corridorHalfWidthM = 1.75;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 地面坐标 → 画布坐标：本车在底部中央
    double toCanvasX(double lateralM) => size.width / 2 + lateralM / widthMeters * size.width;
    double toCanvasY(double forwardM) => size.height - forwardM / maxMeters * size.height;

    // 背景网格：横向每 2m，纵向每 5m
    final gridPaint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;
    final labelStyle = TextStyle(
      color: const Color(0x88FFFFFF),
      fontSize: size.height * 0.045,
    );

    for (var lateral = -widthMeters / 2; lateral <= widthMeters / 2; lateral += 2.0) {
      final x = toCanvasX(lateral);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    for (var forward = 0.0; forward <= maxMeters; forward += 5.0) {
      final y = toCanvasY(forward);
      final isMajor = forward % 10 == 0;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = isMajor ? const Color(0x55FFFFFF) : const Color(0x33FFFFFF)
          ..strokeWidth = isMajor ? 1.4 : 1,
      );
      if (forward > 0) {
        _text(canvas, '${forward.toInt()}m', Offset(3, y + 1), labelStyle);
      }
    }

    // 行驶通道（安全走廊）：自身为中心，左右对称
    final corridorLeft = toCanvasX(-corridorHalfWidthM);
    final corridorRight = toCanvasX(corridorHalfWidthM);
    canvas.drawRect(
      Rect.fromLTRB(corridorLeft, 0, corridorRight, size.height),
      Paint()..color = const Color(0x1410B981),
    );
    canvas.drawLine(
      Offset(corridorLeft, 0),
      Offset(corridorLeft, size.height),
      Paint()
        ..color = const Color(0x5510B981)
        ..strokeWidth = 1,
    );
    canvas.drawLine(
      Offset(corridorRight, 0),
      Offset(corridorRight, size.height),
      Paint()
        ..color = const Color(0x5510B981)
        ..strokeWidth = 1,
    );

    // 本车轮廓（底部中央）
    final egoHeightPx = size.height * 0.07;
    final egoRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height - egoHeightPx / 2),
      width: egoWidthM / widthMeters * size.width,
      height: egoHeightPx,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(egoRect, const Radius.circular(3)),
      Paint()..color = const Color(0xFF6366F1),
    );
    _text(
      canvas,
      '本车',
      Offset(size.width / 2 - size.height * 0.055, size.height - egoHeightPx + 1),
      TextStyle(color: Colors.white, fontSize: size.height * 0.045, fontWeight: FontWeight.w700),
    );

    // 目标
    final objects = snapshot?.objects ?? const <TrackedObject>[];
    for (final object in objects) {
      final distance = object.distance;
      final lateral = object.lateralMeters;
      if (distance == null || lateral == null || !object.isFresh) {
        continue;
      }
      if (distance <= 0.5 || distance > maxMeters) {
        continue;
      }

      final color = switch (object.riskLevel) {
        2 => const Color(0xFFEF4444),
        1 => const Color(0xFFF59E0B),
        _ => const Color(0xFF10B981),
      };

      final center = Offset(toCanvasX(lateral), toCanvasY(distance));
      final halfWidth = 0.9 / widthMeters * size.width; // 目标按约 1.8m 宽示意
      final halfDepth = 2.0 / maxMeters * size.height;

      final marker = Rect.fromCenter(
        center: center,
        width: halfWidth * 2,
        height: halfDepth * 2,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(marker, const Radius.circular(3)),
        Paint()..color = color.withValues(alpha: 0.75),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(marker, const Radius.circular(3)),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = object.riskLevel == 2 ? 2.5 : 1.5,
      );

      // 距离标注
      _text(
        canvas,
        '${distance.toStringAsFixed(1)}m',
        Offset(center.dx - halfWidth, center.dy - halfDepth * 2 - size.height * 0.05),
        TextStyle(
          color: Colors.white,
          fontSize: size.height * 0.05,
          fontWeight: FontWeight.w700,
          shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 2)],
        ),
      );
    }

    // 边框
    canvas.drawRect(
      rect.deflate(0.5),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  void _text(Canvas canvas, String text, Offset at, TextStyle style) {
    TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )
      ..layout()
      ..paint(canvas, at);
  }

  @override
  bool shouldRepaint(_BevPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot ||
      oldDelegate.maxMeters != maxMeters ||
      oldDelegate.widthMeters != widthMeters;
}
