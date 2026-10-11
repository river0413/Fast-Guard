/// 单目逆透视变换（IPM）—— [core/ipm.py](../../../core/ipm.py) 的 Dart 移植。
///
/// 把像素点映射到地平面（X 横向、Y 前方，单位米），用于估计目标距离。
/// 坐标系约定与 Python 版一致：相机位于 (0, H, 0)，俯仰向下为正、偏航左转为正。
library;

import 'dart:math' as math;

/// 地平面坐标。
class GroundPoint {
  const GroundPoint(this.x, this.y);
  final double x;
  final double y;
}

class IpmTransformer {
  IpmTransformer({
    double? fx,
    double? fy,
    double? cx,
    double? cy,
    this.camHeight = 1.4,
    double pitchDeg = 8.0,
    double yawDeg = 0.0,
    this.fovDeg = 90.0,
  })  : _fx = fx,
        _fy = fy,
        _cx = cx,
        _cy = cy,
        _pitch = pitchDeg * math.pi / 180.0,
        _yaw = yawDeg * math.pi / 180.0;

  double? _fx;
  double? _fy;
  double? _cx;
  double? _cy;
  double _pitch;
  double _yaw;

  final double camHeight;
  final double fovDeg;
  int? _frameW;
  int? _frameH;

  double? get fx => _fx;
  double? get fy => _fy;
  double get pitchDeg => _pitch * 180.0 / math.pi;
  double get yawDeg => _yaw * 180.0 / math.pi;

  /// 设置画面尺寸；未显式给出内参时按水平 FOV 估算焦距。
  void setFrame(int width, int height) {
    _frameW = width;
    _frameH = height;
    _cx ??= width * 0.5;
    _cy ??= height * 0.5;
    if (_fx == null || _fy == null) {
      final f = (width * 0.5) / math.tan(fovDeg * math.pi / 180.0 * 0.5);
      _fx ??= f;
      _fy ??= f;
    }
  }

  void setPitchYaw({required double pitchDeg, double yawDeg = 0.0}) {
    _pitch = pitchDeg * math.pi / 180.0;
    _yaw = yawDeg * math.pi / 180.0;
  }

  /// 像素 (u, v) → 地平面 (X, Y)；射线不与地面相交（例如指向天空）时返回 null。
  GroundPoint? pixelToGround(double u, double v, int frameWidth, int frameHeight) {
    if (_frameW != frameWidth || _frameH != frameHeight) {
      setFrame(frameWidth, frameHeight);
    }
    final fx = _fx;
    final fy = _fy;
    final cx = _cx;
    final cy = _cy;
    if (fx == null || fy == null || cx == null || cy == null) {
      return null;
    }

    // 像素 → 相机坐标方向（y 轴向上为正）
    final xCam = (u - cx) / fx;
    final yCam = (cy - v) / fy;
    const zCam = 1.0;

    final cp = math.cos(_pitch);
    final sp = math.sin(_pitch);
    final cyaw = math.cos(_yaw);
    final syaw = math.sin(_yaw);

    // 先俯仰（绕 X），再偏航（绕 Y）
    final y1 = cp * yCam - sp * zCam;
    final z1 = sp * yCam + cp * zCam;
    final x1 = xCam;
    final x2 = cyaw * x1 + syaw * z1;
    final z2 = -syaw * x1 + cyaw * z1;
    final y2 = y1;

    // 直线 P = (0, H, 0) + t·d 与地面 y = 0 求交
    if (y2 >= -1e-6) {
      return null; // 指向地面以上
    }
    final t = camHeight / -y2;
    final groundX = x2 * t;
    final groundY = z2 * t;
    if (groundX.abs() > 50.0 || groundY.abs() > 50.0) {
      return null; // 超出合理范围
    }
    return GroundPoint(groundX, groundY);
  }

  /// 目标框底边中点 → 前方距离（米）；无法求解时返回 null。
  double? distanceFromBottom(double u, double bottomV, int frameWidth, int frameHeight) {
    final point = pixelToGround(u, bottomV, frameWidth, frameHeight);
    if (point == null) {
      return null;
    }
    // Y 为前方距离（米）
    return point.y.abs();
  }

  /// 地平面 (X, Y) → 像素 (u, v)；无法映射时返回 null。
  List<double>? groundToPixel(double x, double y, int frameWidth, int frameHeight) {
    if (_frameW != frameWidth || _frameH != frameHeight) {
      setFrame(frameWidth, frameHeight);
    }
    final fx = _fx;
    final fy = _fy;
    final cx = _cx;
    final cy = _cy;
    if (fx == null || fy == null || cx == null || cy == null) {
      return null;
    }

    final xDir = x;
    final yDir = -camHeight;
    final zDir = y;

    final cp = math.cos(_pitch);
    final sp = math.sin(_pitch);
    final cyaw = math.cos(_yaw);
    final syaw = math.sin(_yaw);

    // 逆偏航
    final x1 = cyaw * xDir - syaw * zDir;
    final z1 = syaw * xDir + cyaw * zDir;
    final y1 = yDir;
    // 逆俯仰
    final y2 = cp * y1 + sp * z1;
    final z2 = -sp * y1 + cp * z1;
    final x2 = x1;

    if (z2 <= 1e-6) {
      return null;
    }
    final xCam = x2 / z2;
    final yCam = y2 / z2;
    return <double>[fx * xCam + cx, cy - fy * yCam];
  }
}
