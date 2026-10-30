/// 某一天的陪伴 / 学习统计（对应服务端 `companion_record` + `chat_message` 汇总）。
class DayStat {
  final String date;
  final int stars;
  final int wordCount;
  final int durationSec;
  final int openCount;
  final int utterances;

  /// 学习计划：只统计当天计划内的词，按词去重。
  final int planWords;
  final int wordsHeard;
  final int wordsSaid;

  const DayStat({
    this.date = '',
    this.stars = 0,
    this.wordCount = 0,
    this.durationSec = 0,
    this.openCount = 0,
    this.utterances = 0,
    this.planWords = 0,
    this.wordsHeard = 0,
    this.wordsSaid = 0,
  });

  factory DayStat.fromJson(Map<String, dynamic> json) => DayStat(
    date: (json['date'] ?? '').toString(),
    stars: _asInt(json['stars']),
    wordCount: _asInt(json['word_count']),
    durationSec: _asInt(json['duration_sec']),
    openCount: _asInt(json['open_count']),
    utterances: _asInt(json['utterances']),
    planWords: _asInt(json['plan_words']),
    wordsHeard: _asInt(json['words_heard']),
    wordsSaid: _asInt(json['words_said']),
  );

  /// `2026-10-25` → `10-25`
  String get shortDate => date.length >= 10 ? date.substring(5) : date;

  /// `2026-10-25` → `周日`
  String get weekdayLabel {
    final d = DateTime.tryParse(date);
    if (d == null) return '';
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return labels[(d.weekday - 1).clamp(0, 6)];
  }

  String get durationText => formatDuration(durationSec);
}

/// 宝宝统计总览（对应 `GET /child/:id/stats`）。
class ChildStats {
  final String childId;
  final DayStat today;
  final DayStat total;
  final List<DayStat> week;
  final int weekStars;
  final int streakDays;
  final int totalUtterances;

  /// 间隔重复：今天到期该复习的词数 / 已经掌握（说出 5 次）的词数。
  final int wordsToReview;
  final int wordsMastered;

  const ChildStats({
    required this.childId,
    this.today = const DayStat(),
    this.total = const DayStat(),
    this.week = const [],
    this.weekStars = 0,
    this.streakDays = 0,
    this.totalUtterances = 0,
    this.wordsToReview = 0,
    this.wordsMastered = 0,
  });

  factory ChildStats.fromJson(Map<String, dynamic> json) => ChildStats(
    childId: (json['child_id'] ?? '').toString(),
    today: DayStat.fromJson(_asMap(json['today'])),
    total: DayStat.fromJson(_asMap(json['total'])),
    week: ((json['week'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => DayStat.fromJson(e.cast<String, dynamic>()))
        .toList(),
    weekStars: _asInt(json['week_stars']),
    streakDays: _asInt(json['streak_days']),
    totalUtterances: _asInt(json['total_utterances']),
    wordsToReview: _asInt(json['words_to_review']),
    wordsMastered: _asInt(json['words_mastered']),
  );

  static ChildStats empty(String childId) => ChildStats(childId: childId);
}

/// 秒 → 「45 秒 / 3 分钟 / 1 小时 5 分」
String formatDuration(int seconds) {
  if (seconds <= 0) return '0 分钟';
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}

Map<String, dynamic> _asMap(dynamic v) {
  if (v is Map) return v.cast<String, dynamic>();
  return const {};
}
