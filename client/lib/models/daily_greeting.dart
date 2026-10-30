/// 每天首次进入角色对话页时的开场话题（中英混排，附角色音色 TTS）。
class DailyGreeting {
  final String roleId;
  final String date;
  final String text;
  final String audioB64;
  final String format;

  /// 今天首次生成 → 客户端自动播放语音；当天再次进入为 false。
  final bool isNew;

  const DailyGreeting({
    required this.roleId,
    required this.date,
    required this.text,
    required this.audioB64,
    this.format = 'mp3',
    required this.isNew,
  });

  factory DailyGreeting.fromJson(Map<String, dynamic> json) {
    return DailyGreeting(
      roleId: json['role_id'] as String? ?? '',
      date: json['date'] as String? ?? '',
      text: json['text'] as String? ?? '',
      audioB64: json['audio_b64'] as String? ?? '',
      format: json['audio_format'] as String? ?? 'mp3',
      isNew: json['is_new'] == true,
    );
  }
}
