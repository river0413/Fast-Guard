import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../core/camera_optics.dart';
import '../inference/model_assets.dart';
import '../pipeline/inference_engine.dart';
import '../settings.dart';
import 'bev_view.dart';
import 'settings_drawer.dart';

/// 端上推理运行状态（右上角徽标据此显示）。
enum EngineState { loading, running, noCamera, error }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.settings});

  final AppSettings settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final InferenceEngine _engine = InferenceEngine(widget.settings);
  final CameraInfoChannel _cameraInfo = CameraInfoChannel();

  List<CameraDescription> _cameras = <CameraDescription>[];
  CameraController? _controller;

  EngineState _state = EngineState.loading;
  String _message = '正在加载端上推理模型…';
  RiskSnapshot? _snapshot;
  CameraOptics? _optics;
  int? _lastFrameWidth;
  bool _busy = false;
  bool _drawerOpen = false;

  /// 正在切换模型：期间不接受新帧，避免会话被关闭时仍有 detect() 在跑。
  bool _modelSwitching = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      await _engine.initialize();
      if (!mounted) return;
      setState(() {
        _state = EngineState.running;
        _message = '推理在手机本地完成';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = EngineState.error;
        _message = '模型加载失败：$error';
      });
      return;
    }
    await _startCamera();
  }

  Future<void> _startCamera() async {
    await _stopCamera();
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _state = EngineState.noCamera;
          _message = '未检测到摄像头';
        });
        return;
      }
      final index = widget.settings.cameraIndex.clamp(0, _cameras.length - 1);
      final controller = CameraController(
        _cameras[index],
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      await controller.startImageStream(_onCameraFrame);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _state = EngineState.running;
        _message = '推理在手机本地完成 · 摄像头 $index';
      });
      _engine.resetTracking();

      // 读取该摄像头的真实光学参数（焦距/传感器），用于针孔测距
      final optics = await _cameraInfo.getCameraInfo(_cameras[index].name);
      if (!mounted) {
        return;
      }
      _engine.setCameraOptics(optics, imageWidth: _lastFrameWidth);
      setState(() => _optics = optics);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _state = EngineState.error;
        _message = '摄像头启动失败：$error';
      });
    }
  }

  Future<void> _stopCamera() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.stopImageStream();
    } catch (_) {
      // 未启动图像流时忽略
    }
    await controller.dispose();
  }

  /// 图像流回调：把 YUV420 转成 RGB 后交给端上推理。
  void _onCameraFrame(CameraImage image) {
    if (_busy || _modelSwitching) {
      return; // 上一帧还在推理，或正在换模型：直接丢帧，避免排队拥塞/会话竞争
    }
    if (image.planes.length < 3) {
      return;
    }
    _busy = true;
    unawaited(_processFrame(image));
  }

  Future<void> _processFrame(CameraImage image) async {
    try {
      _lastFrameWidth = image.width;
      final rgb = yuv420PlanesToRgb(
        yPlane: image.planes[0].bytes,
        uPlane: image.planes[1].bytes,
        vPlane: image.planes[2].bytes,
        width: image.width,
        height: image.height,
        yRowStride: image.planes[0].bytesPerRow,
        uvRowStride: image.planes[1].bytesPerRow,
        uvPixelStride: image.planes[1].bytesPerPixel ?? 2,
      );
      final result = await _engine.processFrame(rgb, image.width, image.height);
      if (result != null && mounted) {
        setState(() => _snapshot = result);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _state = EngineState.error;
          _message = '推理异常：$error';
        });
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _applySettings(AppSettings updated) async {
    final needsCameraRestart = updated.cameraIndex != widget.settings.cameraIndex;
    final needsModelReload = updated.useInt8Model != widget.settings.useInt8Model;
    widget.settings.copyFrom(updated);
    widget.settings.normalized();

    if (needsModelReload) {
      await _reloadModel();
    }
    _engine.applySettings();
    await widget.settings.save();
    if (needsCameraRestart) {
      await _startCamera();
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// 切换 FP32 / INT8 模型：暂停取帧 → 重建会话 → 恢复；失败则回退到原精度。
  Future<void> _reloadModel() async {
    final target = modelAssetFor(int8: widget.settings.useInt8Model);
    _modelSwitching = true;
    setState(() {
      _state = EngineState.loading;
      _message = '正在切换模型：${kModelAssetLabels[target] ?? kModelAssetUnknownLabel}…';
    });
    try {
      await _engine.switchModel(assetKey: target);
      if (!mounted) return;
      setState(() {
        _state = EngineState.running;
        _message = '推理在手机本地完成 · '
            '${kModelAssetLabels[target] ?? kModelAssetUnknownLabel}';
        _snapshot = null;
      });
    } catch (error) {
      // 引擎内部已回退到旧模型；这里把设置也改回去，保证界面与实际一致
      widget.settings.useInt8Model = !widget.settings.useInt8Model;
      await widget.settings.save();
      if (!mounted) return;
      setState(() {
        _state = EngineState.error;
        _message = 'INT8 模型加载失败，已回退到 FP32：$error';
        _snapshot = null;
      });
    } finally {
      _modelSwitching = false;
    }
  }

  Future<void> _resetSettings() async {
    final defaults = AppSettings();
    await _applySettings(defaults);
  }

  @override
  void dispose() {
    unawaited(_stopCamera());
    unawaited(_engine.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _buildPreview(),
          _buildOverlay(),
          if (widget.settings.showBev) _buildBevPanel(),
          if (_drawerOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _drawerOpen = false),
                child: Container(color: Colors.black54),
              ),
            ),
          _buildTopBar(),
          _buildDrawer(),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 画面
  Widget _buildPreview() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const CircularProgressIndicator(color: Color(0xFF6366F1)),
              const SizedBox(height: 20),
              Text(
                _state == EngineState.error ? '端上推理不可用' : '正在准备摄像头与模型',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                _message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFFA1A1AA)),
              ),
            ],
          ),
        ),
      );
    }
    // contain 布局：保持画面比例，黑边填充（坐标映射与之一致）
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: CameraPreview(controller),
      ),
    );
  }

  /// 计算预览画面在屏幕上的实际矩形，供检测框坐标映射使用（与上面的 contain 一致）。
  Rect? _previewRect() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return null;
    }
    final size = MediaQuery.of(context).size;
    final previewAspect = controller.value.aspectRatio;
    var width = size.width;
    var height = width / previewAspect;
    if (height > size.height) {
      height = size.height;
      width = height * previewAspect;
    }
    return Rect.fromLTWH(
      (size.width - width) / 2,
      (size.height - height) / 2,
      width,
      height,
    );
  }

  Widget _buildOverlay() {    final snapshot = _snapshot;
    final rect = _previewRect();
    if (snapshot == null || rect == null) {
      return const SizedBox.shrink();
    }
    // 只在本帧确实检测到目标时才绘制（避免空帧触发重绘计算）
    if (!snapshot.objects.any((object) => object.isFresh)) {
      return const SizedBox.shrink();
    }
    return CustomPaint(
      painter: _DetectionPainter(snapshot: snapshot, previewRect: rect),
      size: Size.infinite,
    );
  }

  // ------------------------------------------------------------------ 俯视图
  /// 右下角俯视图（BEV）画中画。
  Widget _buildBevPanel() {
    final size = MediaQuery.of(context).size;
    final panelWidth = (size.width * 0.26).clamp(180.0, 320.0);
    final panelHeight = (size.height * 0.52).clamp(140.0, 260.0);
    return Positioned(
      right: 12,
      bottom: 12,
      width: panelWidth,
      height: panelHeight,
      child: BevView(snapshot: _snapshot),
    );
  }

  // ------------------------------------------------------------------ 顶栏
  Widget _buildTopBar() {
    final (String text, Color color) = switch (_state) {
      EngineState.loading => ('加载中', const Color(0xFFF59E0B)),
      EngineState.running => ('运行中', const Color(0xFF10B981)),
      EngineState.noCamera => ('无摄像头', const Color(0xFFEF4444)),
      EngineState.error => ('异常', const Color(0xFFEF4444)),
    };

    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 8,
          left: 12,
          right: 12,
          bottom: 8,
        ),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[Color(0xC7000000), Color(0x00000000)],
          ),
        ),
        child: Row(
          children: <Widget>[
            // 左上角汉堡设置栏
            _CircleButton(
              tooltip: '设置：摄像头 / 阈值 / 推理图片大小',
              onTap: () => setState(() => _drawerOpen = !_drawerOpen),
              child: const Icon(Icons.menu, size: 24, color: Colors.white),
            ),
            const Spacer(),
            // 右上角"端上推理"徽标（推理已在本机完成，故不再叫"卸载推理"）
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xBD09090B),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  const Text('端上推理',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  Text(text, style: TextStyle(fontSize: 13, color: color)),
                  if (widget.settings.showDebugOverlay && _snapshot != null) ...<Widget>[
                    const SizedBox(width: 10),
                    Text(
                      '${_snapshot!.inferenceMs.toStringAsFixed(0)}ms · ${_snapshot!.objects.length}目标',
                      style: const TextStyle(fontSize: 12, color: Color(0xFFA1A1AA)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 抽屉
  Widget _buildDrawer() {
    final width = (MediaQuery.of(context).size.width * 0.62).clamp(300.0, 420.0);
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      left: _drawerOpen ? 0 : -width - 8,
      top: 0,
      bottom: 0,
      width: width,
      child: SettingsDrawer(
        settings: widget.settings,
        engineState: _state,
        message: _message,
        snapshot: _snapshot,
        optics: _optics,
        focalLengthPx: _engine.focalLengthPx,
        modelAssetKey: _engine.modelAssetKey,
        onChanged: _applySettings,
        onReset: _resetSettings,
        onClose: () => setState(() => _drawerOpen = false),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.child, required this.onTap, this.tooltip});

  final Widget child;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: const Color(0xB409090B),
      shape: const CircleBorder(side: BorderSide(color: Colors.white24)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(width: 48, height: 48, child: Center(child: child)),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 检测框与风险标注的绘制层。
class _DetectionPainter extends CustomPainter {
  _DetectionPainter({required this.snapshot, required this.previewRect});

  final RiskSnapshot snapshot;
  final Rect previewRect;

  @override
  void paint(Canvas canvas, Size size) {
    // 画面坐标 → 屏幕坐标（含 contain 的缩放与偏移）
    final scaleX = previewRect.width / snapshot.frameWidth;
    final scaleY = previewRect.height / snapshot.frameHeight;

    for (final object in snapshot.objects) {
      if (!object.isFresh) {
        continue; // 本帧没有真的看到它：不画框（TTC 历史仍保留，便于短暂遮挡后恢复）
      }
      final detection = object.detection;
      final rect = Rect.fromLTRB(
        previewRect.left + detection.x1 * scaleX,
        previewRect.top + detection.y1 * scaleY,
        previewRect.left + detection.x2 * scaleX,
        previewRect.top + detection.y2 * scaleY,
      );

      final color = switch (object.riskLevel) {
        2 => const Color(0xFFEF4444),
        1 => const Color(0xFFF59E0B),
        _ => const Color(0xFF10B981),
      };

      // 角框（与 PC 端一致的四角样式，视觉更轻）
      final paint = Paint()
        ..color = color
        ..strokeWidth = object.riskLevel == 2 ? 4 : 2.5
        ..style = PaintingStyle.stroke;
      const corner = 18.0;
      final path = Path()
        ..moveTo(rect.left, rect.top + corner)
        ..lineTo(rect.left, rect.top)
        ..lineTo(rect.left + corner, rect.top)
        ..moveTo(rect.right - corner, rect.top)
        ..lineTo(rect.right, rect.top)
        ..lineTo(rect.right, rect.top + corner)
        ..moveTo(rect.left, rect.bottom - corner)
        ..lineTo(rect.left, rect.bottom)
        ..lineTo(rect.left + corner, rect.bottom)
        ..moveTo(rect.right - corner, rect.bottom)
        ..lineTo(rect.right, rect.bottom)
        ..lineTo(rect.right, rect.bottom - corner);
      canvas.drawPath(path, paint);

      // 标签：类别 + TTC（+ 距离，并标注测距来源）
      final buffer = StringBuffer(detection.className);
      if (object.ttc.riskLevel > 0) {
        buffer.write(' TTC ${object.ttc.ttc.toStringAsFixed(1)}s');
      }
      if (object.distance != null && object.distance! > 0.1 && object.distance! < 50) {
        buffer.write(' ${object.distance!.toStringAsFixed(1)}m');
        final source = object.distanceSource;
        if (source != null && source != 'ipm') {
          buffer.write(source == 'fused' ? '·融' : (source == 'height' ? '·高' : '·宽'));
        }
      }
      final label = buffer.toString();

      final textPainter = TextPainter(
        text: TextSpan(
          text: label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final labelOrigin = Offset(rect.left, rect.top - textPainter.height - 8);
      final labelRect = Rect.fromLTWH(
        labelOrigin.dx,
        labelOrigin.dy,
        textPainter.width + 14,
        textPainter.height + 6,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(labelRect, const Radius.circular(4)),
        Paint()..color = color,
      );
      textPainter.paint(canvas, labelOrigin + const Offset(7, 3));
    }
  }

  @override
  bool shouldRepaint(_DetectionPainter oldDelegate) =>
      oldDelegate.snapshot != snapshot || oldDelegate.previewRect != previewRect;
}
