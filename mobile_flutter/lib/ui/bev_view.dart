/// 俯视图（BEV / IPM 视图）：以本车为中心，把已估出位置的目标画在鸟瞰平面上。
///
/// **为什么不做经典 IPM 反投影**：经典做法要求预先知道相机安装高度与俯仰角
/// （`core/ipm.dart` 里的默认值是 1.4 m / 8°），但手机在车内的实际摆放姿态无法预知。
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
///
/// 视图有两种形态（[BevViewMode]，设置栏或面板右上角按钮切换）：
/// * **方形**：笛卡尔网格，纵向 = 距离、横向 = 横向偏移；
/// * **扇形**：雷达式极坐标，同心距离圈 + 角射线，便于判断"偏离本车道多少度"。
///
/// 每个目标都按类别画不同的矢量标识（见 `bev_icons.dart`），并标注**距离**与
/// **相对速度**（由 TTC 估计，见 `core/relative_speed.dart`）。
/// 远距（长焦）目标单独用青色标记，**只标距离**。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/distance_estimator.dart';
import '../pipeline/far_target_engine.dart';
import '../pipeline/inference_engine.dart';
import 'bev_icons.dart';
import 'bev_view_mode.dart';

/// 风险色（与画面标框、顶栏保持一致）。
const Color kBevSafeColor = Color(0xFF10B981);
const Color kBevWarnColor = Color(0xFFF59E0B);
const Color kBevDangerColor = Color(0xFFEF4444);
const Color kBevEgoColor = Color(0xFF6366F1);

/// 远距（长焦）目标专用色：与风险色区分，表示"只测距离，不参与风险分级"。
const Color kBevFarColor = Color(0xFF22D3EE);

/// 俯视图叠加层。
class BevView extends StatelessWidget {
  const BevView({
    super.key,
    required this.snapshot,
    this.farTargets,
    this.mode = BevViewMode.rectangular,
    this.onToggleMode,
    this.maxMeters = 40.0,
    this.widthMeters = 16.0,
  });

  final RiskSnapshot? snapshot;

  /// 远距（长焦）目标；为 null 或空表示未开启远距监测。
  final FarTargetSnapshot? farTargets;

  /// 当前形态（方形 / 扇形）。
  final BevViewMode mode;

  /// 非 null 时在面板右上角显示"切换形态"按钮。
  final VoidCallback? onToggleMode;

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
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _BevPainter(
                  snapshot: snapshot,
                  farTargets: farTargets,
                  mode: mode,
                  maxMeters: maxMeters,
                  widthMeters: widthMeters,
                ),
                size: Size.infinite,
              ),
            ),
            if (onToggleMode != null)
              Positioned(
                top: 3,
                right: 3,
                child: _ModeToggleButton(mode: mode, onTap: onToggleMode!),
              ),
          ],
        ),
      ),
    );
  }
}

/// 面板右上角的形态切换按钮（方形 ⇄ 扇形）。
class _ModeToggleButton extends StatelessWidget {
  const _ModeToggleButton({required this.mode, required this.onTap});

  final BevViewMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final target = mode.toggled;
    return Tooltip(
      message: '切换为${target.label}视图',
      child: Material(
        color: const Color(0x9909090B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: Colors.white24),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  target == BevViewMode.sector ? Icons.radar : Icons.grid_on,
                  size: 13,
                  color: Colors.white70,
                ),
                const SizedBox(width: 4),
                Text(
                  target.label,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BevPainter extends CustomPainter {
  _BevPainter({
    required this.snapshot,
    required this.farTargets,
    required this.mode,
    required this.maxMeters,
    required this.widthMeters,
  });

  final RiskSnapshot? snapshot;
  final FarTargetSnapshot? farTargets;
  final BevViewMode mode;
  final double maxMeters;
  final double widthMeters;

  /// 本车宽度（米），用于画自车轮廓。
  static const double egoWidthM = 1.9;

  /// 安全通道半宽（米），与 PC 端 `envelope_margin` 一致的量级。
  static const double corridorHalfWidthM = 1.75;

  /// 扇形模式下允许的最大偏角（度）。
  static const double maxSectorAngleDeg = 70.0;

  @override
  void paint(Canvas canvas, Size size) {
    // 地面坐标 → 画布坐标（方形：纵向=距离，横向=横向偏移）
    double toCanvasX(double lateralM) => size.width / 2 + lateralM / widthMeters * size.width;
    double toCanvasY(double forwardM) => size.height - forwardM / maxMeters * size.height;

    // 扇形：本车在下方中央，半径按距离线性缩放
    final sectorOrigin = Offset(size.width / 2, size.height - size.height * 0.06);
    final sectorRadiusPx = size.height * 0.86;
    double sectorR(double forwardM) => forwardM / maxMeters * sectorRadiusPx;

    Offset rectPoint(double lateralM, double forwardM) =>
        Offset(toCanvasX(lateralM), toCanvasY(forwardM));

    /// 扇形取点：角度 = atan2(横向, 纵向)，并限制在 ±[maxSectorAngleDeg] 内。
    Offset sectorPoint(double lateralM, double forwardM) {
      final clampedForward = forwardM <= 0.2 ? 0.2 : forwardM;
      final rawDeg = math.atan2(lateralM, clampedForward) * 180 / math.pi;
      final deg = rawDeg.clamp(-maxSectorAngleDeg, maxSectorAngleDeg);
      final angle = deg * math.pi / 180;
      final radius = sectorR(clampedForward);
      return Offset(
        sectorOrigin.dx + radius * math.sin(angle),
        sectorOrigin.dy - radius * math.cos(angle),
      );
    }

    Offset pointOf(double lateralM, double forwardM) => mode == BevViewMode.sector
        ? sectorPoint(lateralM, forwardM)
        : rectPoint(lateralM, forwardM);

    final labelStyle = TextStyle(
      color: const Color(0x88FFFFFF),
      fontSize: size.height * 0.045,
    );

    if (mode == BevViewMode.sector) {
      _paintSectorBackground(canvas, size, sectorOrigin, sectorRadiusPx, sectorR, labelStyle);
    } else {
      _paintRectBackground(canvas, size, toCanvasX, toCanvasY, labelStyle);
    }

    _paintCorridor(canvas, size, pointOf);
    _paintEgo(canvas, size);
    _paintObjects(canvas, size, pointOf);
    _paintFarTargets(canvas, size, pointOf);

    // 边框
    canvas.drawRect(
      (Offset.zero & size).deflate(0.5),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  // ------------------------------------------------------------------ 底图
  void _paintRectBackground(
    Canvas canvas,
    Size size,
    double Function(double) toCanvasX,
    double Function(double) toCanvasY,
    TextStyle labelStyle,
  ) {
    final gridPaint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;

    // 横向每 2m，纵向每 5m
    for (var lateral = -widthMeters / 2; lateral <= widthMeters / 2 + 1e-6; lateral += 2.0) {
      final x = toCanvasX(lateral);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }

    for (var forward = 0.0; forward <= maxMeters + 1e-6; forward += 5.0) {
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
  }

  void _paintSectorBackground(
    Canvas canvas,
    Size size,
    Offset origin,
    double radiusPx,
    double Function(double) sectorR,
    TextStyle labelStyle,
  ) {
    // 距离圈：每 5m 一圈（范围较大时每 10m），每两圈加亮
    final ringStep = maxMeters <= 40 ? 5.0 : 10.0;
    var ringIndex = 0;
    for (var forward = ringStep; forward <= maxMeters + 1e-6; forward += ringStep) {
      ringIndex += 1;
      final radius = sectorR(forward);
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..color = (ringIndex.isEven) ? const Color(0x55FFFFFF) : const Color(0x33FFFFFF)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
      _text(canvas, '${forward.toInt()}m', Offset(origin.dx + 2, origin.dy - radius + 1), labelStyle);
    }

    // 角射线：每 15°，30° 的整数倍与视野边界加亮并标注角度
    const majorAngles = <double>[-60, -30, 0, 30, 60];
    final angles = <double>[
      -maxSectorAngleDeg,
      for (var deg = -60.0; deg <= 60.0 + 1e-6; deg += 15.0) deg,
      maxSectorAngleDeg,
    ];
    for (final deg in angles) {
      final isMajor = majorAngles.contains(deg) || deg.abs() == maxSectorAngleDeg;
      final angle = deg * math.pi / 180;
      final end = Offset(
        origin.dx + radiusPx * math.sin(angle),
        origin.dy - radiusPx * math.cos(angle),
      );
      canvas.drawLine(
        origin,
        end,
        Paint()
          ..color = isMajor ? const Color(0x55FFFFFF) : const Color(0x22FFFFFF)
          ..strokeWidth = isMajor ? 1.4 : 1,
      );
      if (isMajor) {
        final labelAt = Offset(
          origin.dx + (radiusPx + 2) * math.sin(angle) - size.height * 0.02,
          origin.dy - (radiusPx + 2) * math.cos(angle),
        );
        _text(canvas, '${deg.toInt()}°', labelAt, labelStyle);
      }
    }

    // 扇形外弧；把"视野边界"画实一点
    canvas.drawArc(
      Rect.fromCircle(center: origin, radius: radiusPx),
      -math.pi / 2 - maxSectorAngleDeg * math.pi / 180,
      maxSectorAngleDeg * 2 * math.pi / 180,
      false,
      Paint()
        ..color = const Color(0x99FFFFFF)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(origin, 2.4, Paint()..color = const Color(0x88FFFFFF));
  }

  // ------------------------------------------------------------------ 走廊 / 自车
  void _paintCorridor(Canvas canvas, Size size, Offset Function(double, double) pointOf) {
    final corridorPaint = Paint()..color = const Color(0x1410B981);
    final edgePaint = Paint()
      ..color = const Color(0x5510B981)
      ..strokeWidth = 1;
    if (mode == BevViewMode.sector) {
      // 扇形下安全走廊是一条夹角固定的楔形，宽度随距离自然张开
      final path = Path()
        ..moveTo(pointOf(0, 0.4).dx, pointOf(0, 0.4).dy)
        ..lineTo(pointOf(-corridorHalfWidthM, maxMeters).dx, pointOf(-corridorHalfWidthM, maxMeters).dy)
        ..lineTo(pointOf(corridorHalfWidthM, maxMeters).dx, pointOf(corridorHalfWidthM, maxMeters).dy)
        ..close();
      canvas.drawPath(path, corridorPaint);
      canvas.drawLine(pointOf(0, 0.4), pointOf(-corridorHalfWidthM, maxMeters), edgePaint);
      canvas.drawLine(pointOf(0, 0.4), pointOf(corridorHalfWidthM, maxMeters), edgePaint);
      return;
    }
    final left = pointOf(-corridorHalfWidthM, 0).dx;
    final right = pointOf(corridorHalfWidthM, 0).dx;
    canvas.drawRect(Rect.fromLTRB(left, 0, right, size.height), corridorPaint);
    canvas.drawLine(Offset(left, 0), Offset(left, size.height), edgePaint);
    canvas.drawLine(Offset(right, 0), Offset(right, size.height), edgePaint);
  }

  void _paintEgo(Canvas canvas, Size size) {
    final egoHeightPx = size.height * 0.07;
    final egoRect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height - egoHeightPx / 2),
      width: egoWidthM / widthMeters * size.width,
      height: egoHeightPx,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(egoRect, const Radius.circular(3)),
      Paint()..color = kBevEgoColor,
    );
    _text(
      canvas,
      '本车',
      Offset(size.width / 2 - size.height * 0.055, size.height - egoHeightPx + 1),
      TextStyle(
        color: Colors.white,
        fontSize: size.height * 0.045,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  // ------------------------------------------------------------------ 目标
  void _paintObjects(Canvas canvas, Size size, Offset Function(double, double) pointOf) {
    final objects = snapshot?.objects ?? const <TrackedObject>[];
    for (final object in objects) {
      final distance = object.distance;
      final lateral = object.lateralMeters;
      if (distance == null || lateral == null || !object.isFresh || distance <= 0.5) {
        continue;
      }

      final color = switch (object.riskLevel) {
        2 => kBevDangerColor,
        1 => kBevWarnColor,
        _ => kBevSafeColor,
      };
      // 超出显示范围的目标贴在边界上，并标注"≥"
      final beyond = distance > maxMeters;
      final center = pointOf(lateral, beyond ? maxMeters : distance);

      final metrics = objectMetrics[object.detection.classId];
      final realWidth = metrics?.widthM ?? 1.4;
      final realLength = (metrics != null && metrics.lengthsM.isNotEmpty)
          ? metrics.lengthsM[metrics.lengthsM.length ~/ 2]
          : 1.8;
      // 足迹按真实尺寸缩放，但保证至少放得下图标
      final footprintW = math.max(realWidth / widthMeters * size.width, size.height * 0.05);
      final footprintH = math.max(realLength / maxMeters * size.height, size.height * 0.05);
      final marker = Rect.fromCenter(center: center, width: footprintW, height: footprintH);

      canvas.drawRRect(
        RRect.fromRectAndRadius(marker, const Radius.circular(3)),
        Paint()..color = color.withValues(alpha: 0.28),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(marker, const Radius.circular(3)),
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = object.riskLevel == 2 ? 2.5 : 1.5,
      );

      final iconSide = math.max(math.min(marker.width, marker.height) * 0.78, size.height * 0.05);
      paintBevIcon(
        canvas,
        Rect.fromCenter(center: center, width: iconSide, height: iconSide),
        bevIconKindFor(object.detection.classId),
        color: color,
        strokeWidth: size.height * 0.006 + 0.8,
      );

      _paintObjectLabel(canvas, size, object, marker, color, beyond);
    }
  }

  void _paintObjectLabel(
    Canvas canvas,
    Size size,
    TrackedObject object,
    Rect marker,
    Color color,
    bool beyond,
  ) {
    final distance = object.distance!;
    final distanceText =
        beyond ? '≥${distance.toStringAsFixed(0)}m' : '${distance.toStringAsFixed(1)}m';
    final speed = object.relativeSpeedMps;
    final speedText = speed >= 0.2 ? '相对≈${speed.toStringAsFixed(1)}m/s' : '相对—';

    final fontSize = size.height * 0.05;
    final title = TextPainter(
      text: TextSpan(
        text: '${bevIconKindLabel(bevIconKindFor(object.detection.classId))} $distanceText',
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final sub = TextPainter(
      text: TextSpan(
        text: speedText,
        style: TextStyle(
          color: color,
          fontSize: fontSize * 0.86,
          fontWeight: FontWeight.w600,
          shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 2)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final totalHeight = title.height + sub.height;
    // 默认放标记正上方；扇形下目标可能贴近上边缘，则改为放右侧
    var origin = Offset(marker.center.dx - title.width / 2, marker.top - totalHeight - 4);
    if (origin.dy < 0) {
      origin = Offset(marker.right + 3, marker.center.dy - totalHeight / 2);
    }
    origin = Offset(
      origin.dx.clamp(0.0, math.max(0.0, size.width - title.width)),
      origin.dy.clamp(0.0, math.max(0.0, size.height - totalHeight)),
    );

    title.paint(canvas, origin);
    sub.paint(canvas, origin + Offset(0, title.height));
  }

  /// 远距（长焦）目标：**只标距离**（不参与 TTC / 风险分级）。
  void _paintFarTargets(Canvas canvas, Size size, Offset Function(double, double) pointOf) {
    final targets = farTargets?.targets ?? const <FarTarget>[];
    for (final target in targets) {
      final beyond = target.distanceM > maxMeters;
      final center = pointOf(target.lateralMeters ?? 0.0, beyond ? maxMeters : target.distanceM);

      final radius = math.max(size.height * 0.022, 2.0);
      if (beyond) {
        // 超出显示范围：空心环 + 向上小箭头，表示"还在更远处"
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..color = kBevFarColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
        final arrow = Path()
          ..moveTo(center.dx, center.dy - radius - 2)
          ..lineTo(center.dx - radius * 0.7, center.dy - radius * 2 - 2)
          ..lineTo(center.dx + radius * 0.7, center.dy - radius * 2 - 2)
          ..close();
        canvas.drawPath(arrow, Paint()..color = kBevFarColor.withValues(alpha: 0.85));
      } else {
        canvas.drawCircle(center, radius, Paint()..color = kBevFarColor);
      }

      final text = TextPainter(
        text: TextSpan(
          text: '${target.distanceM.toStringAsFixed(0)}m',
          style: TextStyle(
            color: kBevFarColor,
            fontSize: size.height * 0.048,
            fontWeight: FontWeight.w700,
            shadows: const <Shadow>[Shadow(color: Colors.black, blurRadius: 2)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      var origin = Offset(center.dx + radius + 2, center.dy - text.height / 2);
      if (origin.dx + text.width > size.width) {
        origin = Offset(center.dx - radius - 2 - text.width, origin.dy);
      }
      text.paint(
        canvas,
        Offset(
          origin.dx.clamp(0.0, math.max(0.0, size.width - text.width)),
          origin.dy.clamp(0.0, math.max(0.0, size.height - text.height)),
        ),
      );
    }
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
      oldDelegate.farTargets != farTargets ||
      oldDelegate.mode != mode ||
      oldDelegate.maxMeters != maxMeters ||
      oldDelegate.widthMeters != widthMeters;
}
