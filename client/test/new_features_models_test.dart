import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/bedtime_story.dart';
import 'package:piggy_pal/models/sticker.dart';
import 'package:piggy_pal/models/target_word.dart';

void main() {
  test('目标词解析：缺字段时按未听到/未说出处理', () {
    final w = TargetWord.fromJson({'en': 'cat', 'zh': '猫'});
    expect(w.en, 'cat');
    expect(w.zh, '猫');
    expect(w.heard, isFalse);
    expect(w.said, isFalse);
    expect(w.justSaid, isFalse);

    final said = TargetWord.fromJson({
      'en': 'dog',
      'heard': true,
      'said': true,
      'just_said': true,
    });
    expect(said.heard, isTrue);
    expect(said.said, isTrue);
    expect(said.justSaid, isTrue);
  });

  test('贴纸墙解析：解锁数、下一张待解锁', () {
    final board = StickerBoard.fromJson({
      'child_id': 'anan',
      'total_stars': 30,
      'stickers': [
        {'id': 'star', 'emoji': '⭐', 'name': '小星星', 'stars': 10, 'unlocked': true},
        {'id': 'rainbow', 'emoji': '🌈', 'name': '彩虹', 'stars': 25, 'unlocked': true},
        {'id': 'dino', 'emoji': '🦖', 'name': '小恐龙', 'stars': 50, 'unlocked': false},
      ],
      'next': {'id': 'dino', 'emoji': '🦖', 'name': '小恐龙', 'stars': 50},
    });
    expect(board.totalStars, 30);
    expect(board.unlockedCount, 2);
    expect(board.next?.name, '小恐龙');
    expect(board.next?.stars, 50);
  });

  test('睡前故事解析：文本与音频可空', () {
    final story = BedtimeStory.fromJson({
      'child_id': 'anan',
      'role_id': 'peppa',
      'date': '2026-10-28',
      'text': 'Goodnight, Anan. 晚安。',
      'is_new': true,
    });
    expect(story.text, contains('晚安'));
    expect(story.audioB64, isEmpty);
    expect(story.isNew, isTrue);
  });
}
