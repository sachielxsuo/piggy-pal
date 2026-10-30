/// 一张贴纸：按累计星星解锁，不消费星星。
class Sticker {
  final String id;
  final String emoji;
  final String name;
  final String hint;
  final int stars;
  final bool unlocked;

  const Sticker({
    required this.id,
    required this.emoji,
    this.name = '',
    this.hint = '',
    this.stars = 0,
    this.unlocked = false,
  });

  factory Sticker.fromJson(Map<String, dynamic> json) => Sticker(
    id: (json['id'] ?? '').toString(),
    emoji: (json['emoji'] ?? '⭐').toString(),
    name: (json['name'] ?? '').toString(),
    hint: (json['hint'] ?? '').toString(),
    stars: _asInt(json['stars']),
    unlocked: json['unlocked'] == true,
  );
}

/// 贴纸墙（`GET /child/:id/stickers`）。
class StickerBoard {
  final String childId;
  final int totalStars;
  final List<Sticker> stickers;
  final Sticker? next;

  const StickerBoard({
    required this.childId,
    this.totalStars = 0,
    this.stickers = const [],
    this.next,
  });

  factory StickerBoard.fromJson(Map<String, dynamic> json) => StickerBoard(
    childId: (json['child_id'] ?? '').toString(),
    totalStars: _asInt(json['total_stars']),
    stickers: ((json['stickers'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Sticker.fromJson(e.cast<String, dynamic>()))
        .toList(),
    next: json['next'] is Map
        ? Sticker.fromJson((json['next'] as Map).cast<String, dynamic>())
        : null,
  );

  int get unlockedCount => stickers.where((s) => s.unlocked).length;
}

int _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v') ?? 0;
}
