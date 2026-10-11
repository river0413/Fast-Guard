/// 俯视图（BEV）的两种形态。
///
/// * [rectangular]：方形笛卡尔网格（本车在底部中央，纵向＝距离、横向＝横向偏移）。
/// * [sector]：扇形雷达视图（同心距离圈 + 角射线，便于判断"偏离本车道多少度"）。
///
/// 单独放在这里（而不是塞进 `bev_view.dart`）是为了让 `settings.dart` 能持久化它，
/// 而不必依赖任何 Flutter widget。
library;

enum BevViewMode {
  rectangular,
  sector;

  /// 从持久化字符串解析；未知/缺失时回退 [BevViewMode.rectangular]。
  static BevViewMode fromName(String? name) {
    for (final mode in BevViewMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return BevViewMode.rectangular;
  }

  /// 界面展示名。
  String get label => this == BevViewMode.sector ? '扇形' : '方形';

  /// 切换到另一种形态（用于一键切换按钮）。
  BevViewMode get toggled =>
      this == BevViewMode.sector ? BevViewMode.rectangular : BevViewMode.sector;
}
