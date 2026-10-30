/// 睡前故事（`GET /child/:id/bedtime-story/:role_id`）。
class BedtimeStory {
  final String childId;
  final String roleId;
  final String date;
  final String text;
  final String audioB64;
  final bool isNew;

  const BedtimeStory({
    required this.childId,
    required this.roleId,
    this.date = '',
    this.text = '',
    this.audioB64 = '',
    this.isNew = false,
  });

  factory BedtimeStory.fromJson(Map<String, dynamic> json) => BedtimeStory(
    childId: (json['child_id'] ?? '').toString(),
    roleId: (json['role_id'] ?? '').toString(),
    date: (json['date'] ?? '').toString(),
    text: (json['text'] ?? '').toString(),
    audioB64: (json['audio_b64'] ?? '').toString(),
    isNew: json['is_new'] == true,
  );
}
