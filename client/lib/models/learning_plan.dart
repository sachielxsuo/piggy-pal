/// 学习计划里的一个目标词。
class PlanWord {
  final String en;
  final String zh;

  const PlanWord({required this.en, required this.zh});

  factory PlanWord.fromJson(Map<String, dynamic> json) => PlanWord(
    en: (json['en'] ?? '').toString(),
    zh: (json['zh'] ?? '').toString(),
  );
}

/// 计划中的一天：主题 + 10 个词 + 当天完成情况。
class PlanDay {
  final String date;
  final int dayIndex;
  final String theme;
  final List<PlanWord> words;
  final int heard;
  final int said;
  final List<String> heardWords;
  final List<String> saidWords;

  const PlanDay({
    this.date = '',
    this.dayIndex = 0,
    this.theme = '',
    this.words = const [],
    this.heard = 0,
    this.said = 0,
    this.heardWords = const [],
    this.saidWords = const [],
  });

  factory PlanDay.fromJson(Map<String, dynamic> json) => PlanDay(
    date: (json['date'] ?? '').toString(),
    dayIndex: _asInt(json['day_index']),
    theme: (json['theme'] ?? '').toString(),
    words: ((json['words'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => PlanWord.fromJson(e.cast<String, dynamic>()))
        .toList(),
    heard: _asInt(json['heard']),
    said: _asInt(json['said']),
    heardWords: ((json['heard_words'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    saidWords: ((json['said_words'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
  );

  int get total => words.length;

  bool hasHeard(String en) => heardWords.contains(en);
  bool hasSaid(String en) => saidWords.contains(en);

  /// `2026-10-26` → `周一`
  String get weekdayLabel {
    final d = DateTime.tryParse(date);
    if (d == null) return '';
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[(d.weekday - 1).clamp(0, 6)];
  }

  /// `2026-10-26` → `10-26`
  String get shortDate => date.length >= 10 ? date.substring(5) : date;
}

/// 一周学习计划（`GET /child/:id/learning-plan`）。
class LearningPlan {
  final String childId;
  final String weekStart;
  final List<PlanDay> days;
  final PlanDay today;

  const LearningPlan({
    required this.childId,
    this.weekStart = '',
    this.days = const [],
    this.today = const PlanDay(),
  });

  factory LearningPlan.fromJson(Map<String, dynamic> json) => LearningPlan(
    childId: (json['child_id'] ?? '').toString(),
    weekStart: (json['week_start'] ?? '').toString(),
    days: ((json['days'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => PlanDay.fromJson(e.cast<String, dynamic>()))
        .toList(),
    today: PlanDay.fromJson(
      ((json['today'] as Map?) ?? const {}).cast<String, dynamic>(),
    ),
  );

  static LearningPlan empty(String childId) => LearningPlan(childId: childId);
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
