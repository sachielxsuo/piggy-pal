/// 家长中心 · 每日陪伴时长上限（SharedPreferences 键 `daily_limit_min`）。
///
/// 值为 `0` 表示「不限时」：周末家长在旁边陪护时不自动收尾。
abstract final class TimeLimit {
  static const String prefKey = 'daily_limit_min';
  static const int defaultMinutes = 10;
  static const int minMinutes = 5;
  static const int maxMinutes = 60;

  /// 是否选择了「不限时」。
  static bool isUnlimited(int? saved) => saved != null && saved <= 0;

  /// 规范化存储值：0 原样保留；其余夹到 5~60；未设置用默认 10 分钟。
  static int normalize(int? saved) {
    if (saved == null) return defaultMinutes;
    if (saved <= 0) return 0;
    return saved.clamp(minMinutes, maxMinutes).toInt();
  }
}
