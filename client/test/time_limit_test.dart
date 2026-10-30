import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/time_limit.dart';

void main() {
  group('TimeLimit 每日上限', () {
    test('未设置时默认 10 分钟', () {
      expect(TimeLimit.normalize(null), 10);
    });

    test('0 表示不限时，原样保留（不能被夹成 5 分钟）', () {
      expect(TimeLimit.isUnlimited(0), isTrue);
      expect(TimeLimit.normalize(0), 0);
      expect(TimeLimit.isUnlimited(null), isFalse);
    });

    test('正常值夹在 5~60 分钟之间', () {
      expect(TimeLimit.normalize(5), 5);
      expect(TimeLimit.normalize(30), 30);
      expect(TimeLimit.normalize(60), 60);
      expect(TimeLimit.normalize(1), 5);
      expect(TimeLimit.normalize(999), 60);
    });

    test('负数也按不限时处理', () {
      expect(TimeLimit.isUnlimited(-1), isTrue);
      expect(TimeLimit.normalize(-1), 0);
    });
  });
}
