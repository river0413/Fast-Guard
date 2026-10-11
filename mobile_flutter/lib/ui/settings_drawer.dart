import 'package:flutter/material.dart';

import '../core/camera_optics.dart';
import '../inference/model_assets.dart';
import '../pipeline/inference_engine.dart';
import '../settings.dart';
import 'home_screen.dart' show EngineState;

/// 左上角汉堡设置栏：切换摄像头 / 阈值设置 / 推理图片大小 / 模型精度 / 显示 / 关于。
class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({
    super.key,
    required this.settings,
    required this.engineState,
    required this.message,
    required this.snapshot,
    required this.optics,
    required this.focalLengthPx,
    required this.modelAssetKey,
    required this.onChanged,
    required this.onReset,
    required this.onClose,
  });

  final AppSettings settings;
  final EngineState engineState;
  final String message;
  final RiskSnapshot? snapshot;

  /// 相机真实光学参数（用于展示测距依据）。
  final CameraOptics? optics;

  /// 由设备参数换算出的焦距（像素）。
  final double? focalLengthPx;

  /// 当前已加载的模型资产（用于展示实际生效的精度）。
  final String? modelAssetKey;

  final Future<void> Function(AppSettings updated) onChanged;
  final Future<void> Function() onReset;
  final VoidCallback onClose;

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  late AppSettings _draft = widget.settings.copy();

  Future<void> _commit() async {
    await widget.onChanged(_draft);
    if (mounted) {
      setState(() => _draft = widget.settings.copy());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF18181B),
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
              child: Row(
                children: <Widget>[
                  const Text('设置',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  IconButton(
                    onPressed: widget.onClose,
                    tooltip: '收起设置栏',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                children: <Widget>[
                  _section(title: '切换摄像头', hint: '0 = 后置主摄，1 = 前置；切换后会重新打开相机。'),
                  _segmented<int>(
                    values: kCameraChoices,
                    current: _draft.cameraIndex,
                    label: (value) => value == 0 ? '后置' : '前置',
                    onPick: (value) {
                      setState(() => _draft.cameraIndex = value);
                      _commit();
                    },
                  ),
                  const SizedBox(height: 10),
                  _hint('当前：摄像头 ${_draft.cameraIndex}'
                      '${_draft.cameraIndex == 0 ? '（后置主摄）' : '（前置）'}'),

                  _section(
                    title: '阈值设置',
                    hint: '置信度阈值过滤弱目标；TTC 告警阈值越小越保守。'
                        '（PC 端的「边缘强度阈值」属于预处理增强分支，移动端已按设计要求移除该分支）',
                  ),
                  _slider(
                    label: '置信度阈值',
                    value: _draft.confidence,
                    min: 0.10,
                    max: 0.95,
                    display: _draft.confidence.toStringAsFixed(2),
                    onChanged: (value) => setState(() => _draft.confidence = value),
                    onCommit: _commit,
                  ),
                  _slider(
                    label: 'TTC 告警阈值',
                    value: _draft.ttcThreshold,
                    min: 0.5,
                    max: 5.0,
                    display: '${_draft.ttcThreshold.toStringAsFixed(1)} s',
                    onChanged: (value) => setState(() => _draft.ttcThreshold = value),
                    onCommit: _commit,
                  ),

                  _section(
                    title: '推理图片大小',
                    hint: '对应 YOLO 的 imgsz：越小越快，越大对小目标越友好。'
                        '当前 ONNX 为动态输入，切换无需重新导出模型。',
                  ),
                  _segmented<int>(
                    values: kInferenceSizeChoices,
                    current: _draft.inferenceSize,
                    label: (value) => '${value}px',
                    onPick: (value) {
                      setState(() => _draft.inferenceSize = value);
                      _commit();
                    },
                  ),

                  _section(title: '性能', hint: '每 N 帧推理一次，用于在低端机上保持预览流畅。'),
                  _slider(
                    label: '推理间隔',
                    value: _draft.processEveryNthFrame.toDouble(),
                    min: 1,
                    max: 6,
                    divisions: 5,
                    display: '每 ${_draft.processEveryNthFrame} 帧',
                    onChanged: (value) =>
                        setState(() => _draft.processEveryNthFrame = value.round()),
                    onCommit: _commit,
                  ),

                  _section(title: '显示', hint: '默认只显示行人/车辆等交通参与者。'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _draft.showBev,
                    onChanged: (value) {
                      setState(() => _draft.showBev = value);
                      _commit();
                    },
                    title: const Text('显示俯视图（BEV）', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      '右下角鸟瞰视图：由“真实尺寸+焦距”估出的距离定位目标',
                      style: TextStyle(fontSize: 11, color: Color(0xFF71717A)),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _draft.showAllClasses,
                    onChanged: (value) {
                      setState(() => _draft.showAllClasses = value);
                      _commit();
                    },
                    title: const Text('显示全部 80 类目标', style: TextStyle(fontSize: 14)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _draft.showDebugOverlay,
                    onChanged: (value) {
                      setState(() => _draft.showDebugOverlay = value);
                      _commit();
                    },
                    title: const Text('显示耗时与目标数', style: TextStyle(fontSize: 14)),
                  ),

                  _section(
                    title: '模型精度',
                    hint: '同一网络的两种精度：FP32 为默认；INT8 量化后体积更小'
                        '（10.1 MB → 4.1 MB）。切换会重新加载模型并重置航迹（约 1 秒）。',
                  ),
                  _segmented<bool>(
                    values: const <bool>[false, true],
                    current: _draft.useInt8Model,
                    label: (value) => value
                        ? (kModelAssetLabels[kModelAssetInt8] ?? 'INT8')
                        : (kModelAssetLabels[kModelAssetFp32] ?? 'FP32'),
                    onPick: (value) {
                      setState(() => _draft.useInt8Model = value);
                      _commit();
                    },
                  ),
                  _hint(
                    '实际生效：${widget.modelAssetKey ?? "加载中"}'
                    '${widget.modelAssetKey == kModelAssetInt8 ? "（INT8，检测头保持 FP32）" : ""}',
                  ),
                  if (_draft.useInt8Model)
                    _hint('注意：INT8 的精度取决于量化配方与校准集。本工程的配方已排除检测头'
                        '（否则高置信度会全部塌成 0.50），但速度收益需在你手机上实测确认 ——'
                        '把「显示耗时与目标数」打开，切换前后对比右上角的 ms。'),

                  _section(
                    title: '标框平滑',
                    hint: '用前两帧的移动趋势把框外推到第三帧，再按强度回拉向本帧测量：'
                        '匀速运动不会引入滞后，只有抖动的部分被抑制。画面标框与俯视图同时生效。',
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _draft.boxSmoothing,
                    onChanged: (value) {
                      setState(() => _draft.boxSmoothing = value);
                      _commit();
                    },
                    title: const Text('检测框趋势平滑', style: TextStyle(fontSize: 14)),
                    subtitle: const Text(
                      'TTC 与风险分级仍使用未平滑的原始测量',
                      style: TextStyle(fontSize: 11, color: Color(0xFF71717A)),
                    ),
                  ),
                  _slider(
                    label: '平滑强度',
                    value: _draft.boxSmoothingStrength,
                    min: 0.0,
                    max: 0.9,
                    divisions: 18,
                    display: _draft.boxSmoothing
                        ? _draft.boxSmoothingStrength.toStringAsFixed(2)
                        : '已关闭',
                    onChanged: (value) => setState(() => _draft.boxSmoothingStrength = value),
                    onCommit: _commit,
                  ),

                  _section(title: '运行状态', hint: '推理在本机完成，不依赖网络，也不上传任何画面。'),
                  _hint(widget.message),
                  _hint('当前模型：${widget.modelAssetKey ?? "加载中"}'),
                  if (widget.optics != null) _hint(widget.optics!.describe()),
                  _hint(
                    '测距方式：${widget.focalLengthPx != null ? "真实焦距 + 真实尺寸（针孔模型）" : "IPM 回退（未取到焦距）"}'
                    '${widget.focalLengthPx != null ? "，焦距 ${widget.focalLengthPx!.toStringAsFixed(0)} px" : ""}',
                  ),
                  _hint(
                    '标框平滑：${_draft.boxSmoothing ? "开启（强度 ${_draft.boxSmoothingStrength.toStringAsFixed(2)}）" : "关闭"}'
                    '${widget.snapshot == null ? "" : " · 本帧趋势外推 "
                        "${widget.snapshot!.objects.where((object) => object.smoothed).length}"
                        "/${widget.snapshot!.objects.length} 个目标"}',
                  ),
                  if (widget.snapshot != null)
                    _hint('单帧推理 ${widget.snapshot!.inferenceMs.toStringAsFixed(0)} ms · '
                        '目标 ${widget.snapshot!.objects.length} 个 · '
                        '最小 TTC ${widget.snapshot!.minTtc >= 99 ? '—' : '${widget.snapshot!.minTtc.toStringAsFixed(1)}s'}'),

                  _section(title: '关于', hint: 'FastGuard 移动端 · Flutter + ONNX Runtime（端上推理）'),
                  _hint('模型：${widget.modelAssetKey ?? kModelAssetFp32}'
                      '（输入 1×3×S×S，输出 1×84×N）'),
                  _hint('参数摘要：${_draft.summary}'),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () async {
                      await widget.onReset();
                      if (mounted) {
                        setState(() => _draft = widget.settings.copy());
                      }
                    },
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复默认值'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section({required String title, String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          if (hint != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(hint,
                style: const TextStyle(fontSize: 12, color: Color(0xFFA1A1AA), height: 1.45)),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Color(0xFFA1A1AA), height: 1.45)),
      );

  Widget _segmented<T>({
    required List<T> values,
    required T current,
    required String Function(T) label,
    required void Function(T) onPick,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: values.map((value) {
        final selected = value == current;
        return SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: () => onPick(value),
            style: OutlinedButton.styleFrom(
              backgroundColor: selected ? const Color(0xFF6366F1) : const Color(0xFF27272A),
              side: BorderSide(color: selected ? const Color(0xFF818CF8) : const Color(0xFF3F3F46)),
              foregroundColor: selected ? Colors.white : const Color(0xFFA1A1AA),
            ),
            child: Text(label(value),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
        );
      }).toList(),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    int? divisions,
    required ValueChanged<double> onChanged,
    required Future<void> Function() onCommit,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(display,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF818CF8))),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          onChangeEnd: (_) => onCommit(),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
