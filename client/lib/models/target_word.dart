/// 今日目标词在最近一轮对话后的状态（服务端 `target_words`）。
class TargetWord {
  final String en;
  final String zh;
  final bool heard;
  final bool said;

  /// 就是这一轮说中的：客户端用来高亮和庆祝。
  final bool justSaid;

  const TargetWord({
    required this.en,
    this.zh = '',
    this.heard = false,
    this.said = false,
    this.justSaid = false,
  });

  factory TargetWord.fromJson(Map<String, dynamic> json) => TargetWord(
    en: (json['en'] ?? '').toString(),
    zh: (json['zh'] ?? '').toString(),
    heard: json['heard'] == true,
    said: json['said'] == true,
    justSaid: json['just_said'] == true,
  );
}
