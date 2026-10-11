/// 左上角设置栏：**两层**结构。
///
/// 一级是分组（每个分组在标题下显示当前值摘要，不进去也能看清状态），
/// 点进分组才是具体设置项。这样做的原因：设置项已经增加到 15 个以上，
/// 平铺成长列表会让人找不到重点，也不好在真机上快速核对某一项。
///
/// 层级用内部状态（[_page]）实现而不是 `Navigator`：抽屉本身就是浮层，
/// 再压一层路由会让返回手势与关闭行为互相打架；这里用一个"返回"按钮回到一级。
library;

import 'package:flutter/material.dart';

import '../core/camera_optics.dart';
import '../inference/model_assets.dart';
import '../pipeline/far_target_engine.dart';
import '../pipeline/inference_engine.dart';
import '../settings.dart';
import 'bev_view_mode.dart';
import 'home_screen.dart' show EngineState;

/// 设置栏的一级分组。
enum SettingsPage {
  root('设置'),
  camera('摄像头'),
  risk('检测与告警'),
  model('推理与模型'),
  display('显示与俯视图'),
  smoothing('标框平滑'),
  far('远距监测'),
  status('运行状态'),
  about('关于');

  const SettingsPage(this.title);

  final String title;
}

/// 左上角汉堡设置栏。
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
    this.farSnapshot,
    this.farCameraLabel,
    this.farUnavailableReason,
    this.farFallbackNote,
    this.farFocalLengthPx,
    this.onToggleBevMode,
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

  /// 最近一帧远距（长焦/裁切）结果。
  final FarTargetSnapshot? farSnapshot;

  /// 已选中的长焦镜头描述（成功打开后非空）。
  final String? farCameraLabel;

  /// 远距监测不可用的原因（null = 可用或未开启）。
  final String? farUnavailableReason;

  /// 回退说明（长焦不可用、已改用主摄中心裁切时给出）。
  final String? farFallbackNote;

  /// 长焦换算出的焦距（像素；回退模式下为 null）。
  final double? farFocalLengthPx;

  /// 切换俯视图形态（方形 ⇄ 扇形）；与俯视图面板右上角按钮等效。
  final Future<void> Function()? onToggleBevMode;

  final Future<void> Function(AppSettings updated) onChanged;
  final Future<void> Function() onReset;
  final VoidCallback onClose;

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  late AppSettings _draft = widget.settings.copy();

  /// 当前所在层级；[SettingsPage.root] 为一级分组列表。
  SettingsPage _page = SettingsPage.root;

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
            _buildHeader(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                children: _buildPage(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 头部（层级导航）
  Widget _buildHeader() {
    final isRoot = _page == SettingsPage.root;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 10, 12, 6),
      child: Row(
        children: <Widget>[
          if (!isRoot)
            IconButton(
              onPressed: () => setState(() => _page = SettingsPage.root),
              tooltip: '返回上一层',
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 10),
          if (!isRoot)
            const Text('设置',
                style: TextStyle(fontSize: 14, color: Color(0xFF71717A))),
          if (!isRoot)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.chevron_right, size: 16, color: Color(0xFF52525B)),
            ),
          Expanded(
            child: Text(
              _page.title,
              style: TextStyle(
                fontSize: isRoot ? 20 : 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            tooltip: '收起设置栏',
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 分级内容
  List<Widget> _buildPage() {
    switch (_page) {
      case SettingsPage.root:
        return _buildRoot();
      case SettingsPage.camera:
        return _buildCamera();
      case SettingsPage.risk:
        return _buildRisk();
      case SettingsPage.model:
        return _buildModel();
      case SettingsPage.display:
        return _buildDisplay();
      case SettingsPage.smoothing:
        return _buildSmoothing();
      case SettingsPage.far:
        return _buildFar();
      case SettingsPage.status:
        return _buildStatus();
      case SettingsPage.about:
        return _buildAbout();
    }
  }

  /// 一级：分组列表（副标题直接显示当前值，不进去也能核对）。
  List<Widget> _buildRoot() {
    final draft = _draft;
    final farState = !draft.farTargetEnabled
        ? '关闭'
        : '开启 · ${draft.farDistanceThresholdM.toStringAsFixed(0)}m+ · '
            '${widget.farFallbackNote != null ? '主摄裁切' : (widget.farCameraLabel != null ? '长焦' : '准备中')}';
    final status = '${_engineStateLabel(widget.engineState)}'
        '${widget.snapshot == null ? '' : ' · ${widget.snapshot!.inferenceMs.toStringAsFixed(0)}ms'
            ' · ${widget.snapshot!.objects.length}目标'}';

    return <Widget>[
      _groupTile(
        page: SettingsPage.camera,
        icon: Icons.photo_camera_outlined,
        title: '摄像头',
        subtitle: '摄像头 ${draft.cameraIndex}'
            '（${draft.cameraIndex == 0 ? '后置主摄' : '前置'}）'
            '${widget.optics == null ? '' : ' · ${widget.optics!.focalLength35mmEq?.toStringAsFixed(1) ?? '-'}mm等效'}',
      ),
      _groupTile(
        page: SettingsPage.risk,
        icon: Icons.warning_amber_outlined,
        title: '检测与告警',
        subtitle: '置信度 ${draft.confidence.toStringAsFixed(2)} · '
            'TTC ${draft.ttcThreshold.toStringAsFixed(1)}s',
      ),
      _groupTile(
        page: SettingsPage.model,
        icon: Icons.memory_outlined,
        title: '推理与模型',
        subtitle: '${draft.inferenceSize}px · ${draft.useInt8Model ? 'INT8' : 'FP32'} · '
            '每 ${draft.processEveryNthFrame} 帧推理',
      ),
      _groupTile(
        page: SettingsPage.display,
        icon: Icons.grid_view_outlined,
        title: '显示与俯视图',
        subtitle: draft.showBev
            ? '俯视图开 · ${draft.bevViewMode.label} · '
                '${draft.showAllClasses ? '全部 80 类' : '仅交通参与者'}'
            : '俯视图关 · ${draft.showAllClasses ? '全部 80 类' : '仅交通参与者'}',
      ),
      _groupTile(
        page: SettingsPage.smoothing,
        icon: Icons.timeline_outlined,
        title: '标框平滑',
        subtitle: draft.boxSmoothing
            ? '开启 · 强度 ${draft.boxSmoothingStrength.toStringAsFixed(2)}'
            : '关闭',
      ),
      _groupTile(
        page: SettingsPage.far,
        icon: Icons.zoom_in_outlined,
        title: '远距监测',
        subtitle: farState,
      ),
      _groupTile(
        page: SettingsPage.status,
        icon: Icons.monitor_heart_outlined,
        title: '运行状态',
        subtitle: status,
      ),
      _groupTile(
        page: SettingsPage.about,
        icon: Icons.info_outline,
        title: '关于',
        subtitle: '${widget.modelAssetKey ?? kModelAssetFp32} · 参数摘要与恢复默认',
      ),
    ];
  }

  Widget _groupTile({
    required SettingsPage page,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 2),
      leading: Icon(icon, size: 22, color: const Color(0xFF818CF8)),
      title: Text(title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(subtitle,
            style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF), height: 1.35)),
      ),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFF71717A)),
      onTap: () => setState(() => _page = page),
    );
  }

  // ------------------------------------------------------------------ 摄像头
  List<Widget> _buildCamera() => <Widget>[
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
        _hint('当前：摄像头 ${_draft.cameraIndex}'
            '${_draft.cameraIndex == 0 ? '（后置主摄）' : '（前置）'}'),
        _section(title: '该摄像头的真实光学参数', hint: '针孔测距的依据，由平台通道直接读取 CameraCharacteristics。'),
        _hint(widget.optics?.describe() ?? '未取到（将回退 IPM 测距）'),
        _hint(
          '测距方式：${widget.focalLengthPx != null ? "真实焦距 + 真实尺寸（针孔模型）" : "IPM 回退（未取到焦距）"}'
          '${widget.focalLengthPx != null ? "，焦距 ${widget.focalLengthPx!.toStringAsFixed(0)} px" : ""}',
        ),
      ];

  // ------------------------------------------------------------------ 检测与告警
  List<Widget> _buildRisk() => <Widget>[
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
        _section(title: '风险分级说明', hint: '两种告警等级都要求目标落在画面中央的行驶通道内（35%–65%）。'),
        _hint('注意：TTC < ${_draft.ttcThreshold.toStringAsFixed(1)}s'),
        _hint('危险：TTC < ${(_draft.ttcThreshold * 0.75).toStringAsFixed(1)}s 且距离 < SDT'
            '（SDT = 本车速度 × 1.2s + 2m，本车速度未接入时为 2m）'),
        if (widget.snapshot != null)
          _hint('本帧：目标 ${widget.snapshot!.objects.length} 个 · '
              '最小 TTC ${widget.snapshot!.minTtc >= 99 ? '—' : '${widget.snapshot!.minTtc.toStringAsFixed(1)}s'} · '
              '最高风险 ${_riskLabel(widget.snapshot!.riskLevel)}'),
      ];

  // ------------------------------------------------------------------ 推理与模型
  List<Widget> _buildModel() => <Widget>[
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
      ];

  // ------------------------------------------------------------------ 显示与俯视图
  List<Widget> _buildDisplay() => <Widget>[
        _section(title: '目标过滤', hint: '默认只显示行人/两轮车/车辆等交通参与者。'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _draft.showAllClasses,
          onChanged: (value) {
            setState(() => _draft.showAllClasses = value);
            _commit();
          },
          title: const Text('显示全部 80 类目标', style: TextStyle(fontSize: 14)),
        ),
        _section(
          title: '俯视图（BEV）',
          hint: '右下角画中画：按类别画矢量标识，并标注距离与相对速度'
              '（相对速度由 距离 ÷ TTC 估计）。',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _draft.showBev,
          onChanged: (value) {
            setState(() => _draft.showBev = value);
            _commit();
          },
          title: const Text('显示俯视图（BEV）', style: TextStyle(fontSize: 14)),
        ),
        if (_draft.showBev) ...<Widget>[
          const SizedBox(height: 6),
          _segmented<BevViewMode>(
            values: const <BevViewMode>[BevViewMode.rectangular, BevViewMode.sector],
            current: _draft.bevViewMode,
            label: (value) => value == BevViewMode.sector ? '扇形' : '方形',
            onPick: (value) {
              setState(() => _draft.bevViewMode = value);
              _commit();
            },
          ),
          _hint(_draft.bevViewMode == BevViewMode.sector
              ? '扇形：同心距离圈 + 角射线，便于判断目标偏离本车道多少度'
              : '方形：纵向=距离、横向=横向偏移的笛卡尔网格'),
          if (widget.onToggleBevMode != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await widget.onToggleBevMode!();
                  if (mounted) {
                    setState(() => _draft = widget.settings.copy());
                  }
                },
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: Text('立即切换为${_draft.bevViewMode.toggled.label}视图'),
              ),
            ),
          _hint('提示：俯视图右上角的小按钮也能一键切换形态。'),
        ],
        _section(title: '调试信息', hint: '显示单帧耗时、目标数与远距目标数（右上角徽标）。'),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _draft.showDebugOverlay,
          onChanged: (value) {
            setState(() => _draft.showDebugOverlay = value);
            _commit();
          },
          title: const Text('显示耗时与目标数', style: TextStyle(fontSize: 14)),
        ),
      ];

  // ------------------------------------------------------------------ 标框平滑
  List<Widget> _buildSmoothing() => <Widget>[
        _section(
          title: '趋势平滑',
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
        _hint(
          '本帧趋势外推：${widget.snapshot == null ? "—" : "${widget.snapshot!.objects.where((object) => object.smoothed).length}"
              "/${widget.snapshot!.objects.length} 个目标"}',
        ),
      ];

  // ------------------------------------------------------------------ 远距监测
  List<Widget> _buildFar() => <Widget>[
        _section(
          title: '远距监测（后置）',
          hint: '优先用后置长焦并发双流（主摄与长焦同时拍摄，长焦按 2:1 的配比参与推理：'
              '主摄每 2 帧、长焦 1 帧）。'
              '若机型的长焦不对第三方应用开放（不少 ROM 如此），自动回退为**主摄中心裁切**'
              '（数字变焦）：同样能监视远处目标，只是分辨率不如真长焦。'
              '远距目标**只标出距离**，不参与 TTC 与风险分级。',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _draft.farTargetEnabled,
          onChanged: (value) {
            setState(() => _draft.farTargetEnabled = value);
            _commit();
          },
          title: const Text('开启远距监测', style: TextStyle(fontSize: 14)),
          subtitle: const Text(
            '仅后置主摄下可用；长焦不可用时自动改用主摄中心裁切',
            style: TextStyle(fontSize: 11, color: Color(0xFF71717A)),
          ),
        ),
        if (_draft.farTargetEnabled) ...<Widget>[
          const SizedBox(height: 6),
          _segmented<double>(
            values: kFarDistanceChoices,
            current: _draft.farDistanceThresholdM,
            label: (value) => '${value.toStringAsFixed(0)}m',
            onPick: (value) {
              setState(() => _draft.farDistanceThresholdM = value);
              _commit();
            },
          ),
          _hint('远距阈值 ${_draft.farDistanceThresholdM.toStringAsFixed(0)} m：'
              '只显示比它更远的目标'),
          _hint(_farStatusText()),
          if (widget.farSnapshot != null)
            _hint('单帧远距推理 ${widget.farSnapshot!.inferenceMs.toStringAsFixed(0)} ms · '
                '远距 ${widget.farSnapshot!.targets.length} 个 · '
                '不够远 ${widget.farSnapshot!.nearCount} 个'),
        ] else if (widget.farUnavailableReason != null)
          _hint('远距监测不可用：${widget.farUnavailableReason}'),
      ];

  /// 远距监测的实时状态：不可用原因 / 回退说明 / 已打开的长焦 / 本帧远距目标数。
  String _farStatusText() {
    final reason = widget.farUnavailableReason;
    if (reason != null) {
      return '远距监测不可用：$reason';
    }
    final count =
        widget.farSnapshot == null ? '' : ' · 远距目标 ${widget.farSnapshot!.targets.length} 个';
    final fallback = widget.farFallbackNote;
    if (fallback != null) {
      return '已回退：$fallback$count';
    }
    final camera = widget.farCameraLabel;
    if (camera != null) {
      final focal = widget.farFocalLengthPx;
      return '长焦：$camera${focal != null ? '，焦距 ${focal.toStringAsFixed(0)} px' : ''}$count';
    }
    return '正在尝试打开长焦并发流…';
  }

  // ------------------------------------------------------------------ 运行状态
  List<Widget> _buildStatus() => <Widget>[
        _section(title: '引擎', hint: '推理在本机完成，不依赖网络，也不上传任何画面。'),
        _hint(widget.message),
        _hint('状态：${_engineStateLabel(widget.engineState)}'),
        _hint('当前模型：${widget.modelAssetKey ?? "加载中"}'),
        if (widget.snapshot != null)
          _hint('单帧推理 ${widget.snapshot!.inferenceMs.toStringAsFixed(0)} ms · '
              '目标 ${widget.snapshot!.objects.length} 个 · '
              '最小 TTC ${widget.snapshot!.minTtc >= 99 ? '—' : '${widget.snapshot!.minTtc.toStringAsFixed(1)}s'}'),
        _section(title: '测距与相机', hint: '距绝对精度需在已知距离场景核对，属于未验证项。'),
        _hint(widget.optics?.describe() ?? '相机光学参数未取到'),
        _hint(
          '测距方式：${widget.focalLengthPx != null ? "真实焦距 + 真实尺寸（针孔模型）" : "IPM 回退（未取到焦距）"}'
          '${widget.focalLengthPx != null ? "，焦距 ${widget.focalLengthPx!.toStringAsFixed(0)} px" : ""}',
        ),
        _section(title: '各功能当前状态', hint: '便于真机核对，不必逐个进二级页。'),
        _hint('标框平滑：${_draft.boxSmoothing ? "开启（强度 ${_draft.boxSmoothingStrength.toStringAsFixed(2)}）" : "关闭"}'),
        _hint('俯视图：${_draft.showBev ? "${_draft.bevViewMode.label}形态" : "未显示"}'),
        _hint('远距监测：${!_draft.farTargetEnabled ? "关闭" : "开启 · ${_draft.farDistanceThresholdM.toStringAsFixed(0)}m+ · ${_farSourceLabel()}"}'),
      ];

  String _farSourceLabel() {
    if (widget.farFallbackNote != null) {
      return '主摄中心裁切（数字变焦）';
    }
    if (widget.farCameraLabel != null) {
      return '长焦并发';
    }
    return '准备中';
  }

  // ------------------------------------------------------------------ 关于
  List<Widget> _buildAbout() => <Widget>[
        _section(title: '关于', hint: 'FastGuard 移动端 · Flutter + ONNX Runtime（端上推理）'),
        _hint('版本：$kAppVersion'),
        _hint('模型：${widget.modelAssetKey ?? kModelAssetFp32}'
            '（输入 1×3×S×S，输出 1×84×N）'),
        _hint('参数摘要：${_draft.summary}'),
        _section(title: '恢复默认值', hint: '把所有设置改回出厂默认（摄像头、阈值、模型精度、显示、远距监测）。'),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              await widget.onReset();
              if (mounted) {
                setState(() {
                  _draft = widget.settings.copy();
                  _page = SettingsPage.root;
                });
              }
            },
            icon: const Icon(Icons.restart_alt),
            label: const Text('恢复默认值'),
          ),
        ),
      ];

  String _riskLabel(int level) => switch (level) {
        2 => '危险',
        1 => '注意',
        _ => '安全',
      };

  String _engineStateLabel(EngineState state) => switch (state) {
        EngineState.loading => '加载中',
        EngineState.running => '运行中',
        EngineState.noCamera => '无摄像头',
        EngineState.error => '异常',
      };

  // ------------------------------------------------------------------ 小组件
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
            Text(label, style: const TextStyle(fontSize: 13)),
            const Spacer(),
            Text(display,
                style: const TextStyle(fontSize: 13, color: Color(0xFF818CF8))),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: (_) => onCommit(),
        ),
      ],
    );
  }
}

/// 界面展示用版本号；与 `pubspec.yaml` 的 `version:` 保持一致（不含 build number）。
const String kAppVersion = '1.1.1';
