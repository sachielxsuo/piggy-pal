import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/chat_message.dart';
import 'package:piggy_pal/models/child.dart';
import 'package:piggy_pal/models/child_stats.dart';
import 'package:piggy_pal/models/learning_plan.dart';

void main() {
  group('Child 模型', () {
    test('fromJson 解析完整字段', () {
      final c = Child.fromJson({
        'child_id': 'anan',
        'family_id': 'default',
        'name': '安安',
        'en_name': 'Anna',
        'age': 4,
        'gender': '女',
        'preferences': '恐龙、儿歌',
        'avatar': 'a.png',
      });
      expect(c.childId, 'anan');
      expect(c.familyId, 'default');
      expect(c.name, '安安');
      expect(c.enName, 'Anna');
      expect(c.age, 4);
      expect(c.gender, '女');
      expect(c.preferences, '恐龙、儿歌');
      expect(c.avatar, 'a.png');
    });

    test('fromJson 缺省字段回退默认值', () {
      final c = Child.fromJson({'child_id': 'bob', 'name': 'Bob'});
      expect(c.childId, 'bob');
      expect(c.familyId, 'default');
      expect(c.enName, '');
      expect(c.age, 0);
      expect(c.gender, '');
      expect(c.preferences, '');
      expect(c.avatar, '');
    });

    test('toJson 序列化', () {
      const c = Child(
        childId: 'anan',
        name: '安安',
        enName: 'Anna',
        age: 4,
        preferences: '恐龙',
        avatar: '🦖',
      );
      final j = c.toJson();
      expect(j['child_id'], 'anan');
      expect(j['name'], '安安');
      expect(j['en_name'], 'Anna');
      expect(j['age'], 4);
      expect(j['preferences'], '恐龙');
      expect(j['avatar'], '🦖');
      expect(j['family_id'], 'default');
    });

    test('isDevChild 识别测试宝宝（family_id=dev 或 dev_ 前缀）', () {
      // 生产宝宝：两种条件都不满足
      expect(const Child(childId: 'anan', name: '安安').isDevChild, isFalse);
      expect(
        const Child(
          childId: 'anan',
          familyId: 'default',
          name: '安安',
        ).isDevChild,
        isFalse,
      );

      // family_id 为 dev
      expect(
        const Child(
          childId: 'some_child',
          familyId: 'dev',
          name: '测试宝宝',
        ).isDevChild,
        isTrue,
      );

      // child_id 以 dev_ 开头（即使 family_id 是 default）
      expect(
        const Child(childId: 'dev_child_test', name: '测试宝宝').isDevChild,
        isTrue,
      );

      // 只有中间含 dev_ 不算
      expect(
        const Child(childId: 'child_dev_x', name: '宝宝').isDevChild,
        isFalse,
      );

      // 从接口解析出来的也能识别
      final parsed = Child.fromJson({
        'child_id': 'dev_child_test',
        'family_id': 'dev',
        'name': '测试宝宝',
      });
      expect(parsed.isDevChild, isTrue);
    });
  });

  group('ChildStats 模型', () {
    test('fromJson 解析今日 / 7 天 / 连续天数', () {
      final s = ChildStats.fromJson({
        'child_id': 'anan',
        'today': {
          'date': '2026-10-25',
          'stars': 2,
          'word_count': 5,
          'duration_sec': 90,
          'open_count': 1,
          'utterances': 3,
          'plan_words': 10,
          'words_heard': 6,
          'words_said': 2,
        },
        'total': {'stars': 20, 'duration_sec': 600, 'utterances': 18},
        'week': [
          {'date': '2026-10-24', 'stars': 1},
          {'date': '2026-10-25', 'stars': 2, 'utterances': 3},
        ],
        'week_stars': 3,
        'streak_days': 4,
        'total_utterances': 18,
      });
      expect(s.childId, 'anan');
      expect(s.today.stars, 2);
      expect(s.today.utterances, 3);
      expect(s.today.durationText, '1 分钟');
      expect(s.today.planWords, 10);
      expect(s.today.wordsHeard, 6);
      expect(s.today.wordsSaid, 2);
      expect(s.total.stars, 20);
      expect(s.week.length, 2);
      expect(s.week.last.weekdayLabel, '周日');
      expect(s.weekStars, 3);
      expect(s.streakDays, 4);
      expect(s.totalUtterances, 18);
    });

    test('缺省字段回退默认值', () {
      final s = ChildStats.fromJson({'child_id': 'bob'});
      expect(s.today.stars, 0);
      expect(s.week, isEmpty);
      expect(s.streakDays, 0);
    });

    test('formatDuration 分档显示', () {
      expect(formatDuration(0), '0 分钟');
      expect(formatDuration(45), '45 秒');
      expect(formatDuration(600), '10 分钟');
      expect(formatDuration(3900), '1 小时 5 分');
      expect(formatDuration(3600), '1 小时');
    });
  });

  group('LearningPlan 模型', () {
    test('解析一周计划与完成状态', () {
      final plan = LearningPlan.fromJson({
        'child_id': 'anan',
        'week_start': '2026-10-26',
        'days': [
          {
            'date': '2026-10-26',
            'day_index': 0,
            'theme': '动物朋友',
            'words': [
              {'en': 'cat', 'zh': '猫'},
              {'en': 'dog', 'zh': '狗'},
            ],
            'heard': 1,
            'said': 1,
            'heard_words': ['cat'],
            'said_words': ['cat'],
          },
        ],
        'today': {
          'date': '2026-10-26',
          'theme': '动物朋友',
          'words': [
            {'en': 'cat', 'zh': '猫'},
          ],
          'heard_words': ['cat'],
          'said_words': ['cat'],
        },
      });
      expect(plan.childId, 'anan');
      expect(plan.days.length, 1);
      expect(plan.days.first.weekdayLabel, '周一');
      expect(plan.days.first.total, 2);
      expect(plan.days.first.hasHeard('cat'), isTrue);
      expect(plan.days.first.hasSaid('dog'), isFalse);
      expect(plan.today.words.single.zh, '猫');
    });

    test('缺省字段回退默认值', () {
      final plan = LearningPlan.fromJson({'child_id': 'bob'});
      expect(plan.days, isEmpty);
      expect(plan.today.words, isEmpty);
    });
  });

  group('ChatMsg 模型', () {
    test('构造文本消息', () {
      const m = ChatMsg(who: 'ai', text: 'Hello!');
      expect(m.who, 'ai');
      expect(m.text, 'Hello!');
      expect(m.audioB64, isNull);
    });

    test('构造带音频的消息', () {
      const m = ChatMsg(who: 'ai', text: 'Hello!', audioB64: 'AAAA');
      expect(m.audioB64, 'AAAA');
    });
  });
}
