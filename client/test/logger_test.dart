import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piggy_pal/services/logger.dart';

void main() {
  _retentionTests();

  group('AppLog.excerptFrom', () {
    test('只保留最近两小时，并保留错误堆栈续行', () {
      const all = '''
2026-10-25 08:00:00.000 [I] api: → GET /old
2026-10-25 08:00:00.100 [I] api: ← 200 /old
2026-10-25 10:30:00.000 [I] api: → GET /roles
2026-10-25 10:30:00.100 [W] home: 读取宝宝缓存失败
PlatformException(...)
2026-10-25 10:31:00.000 [I] app: 启动 release
''';

      final out = AppLog.excerptFrom(all, now: DateTime(2026, 10, 25, 11, 30));

      expect(out.isEmpty, isFalse);
      expect(out.text, contains('GET /roles'));
      expect(out.text, contains('PlatformException'));
      expect(out.text, contains('启动 release'));
      expect(out.text, isNot(contains('/old')));
      expect(out.lineCount, 4);
    });

    test('文件名使用切片内最早日志的起始时间', () {
      const all = '''
2026-10-25 08:00:00.000 [I] old
2026-10-25 09:27:24.100 [I] api: → GET /roles
2026-10-25 09:28:00.000 [I] api: ← 200
''';
      final out = AppLog.excerptFrom(all, now: DateTime(2026, 10, 25, 11, 0));

      expect(out.fileName, '2026-10-25_09-27-24.log');
      expect(out.start, DateTime(2026, 10, 25, 9, 27, 24));
    });

    test('窗口内没有日志时返回空', () {
      const all = '2026-10-25 08:00:00.000 [I] old\n';
      final out = AppLog.excerptFrom(all, now: DateTime(2026, 10, 25, 11, 0));
      expect(out.isEmpty, isTrue);
      expect(out.fileName, 'unknown.log');
    });
  });
}

void _retentionTests() {
  group('本地日志保留', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('piggy-log-test-');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('只删超过 14 天的 app-*.log，边界当天和别的文件都保留', () async {
      final now = DateTime(2026, 10, 25, 3, 30);
      for (final name in [
        'app-2026-09-30.log', // 25 天前：删
        'app-2026-10-11.log', // 14 天前：删（今天是第 1 天）
        'app-2026-10-12.log', // 13 天前：保留（边界）
        'app-2026-10-25.log', // 今天：保留
        'server.log', // 非 App 日志：不碰
        'app-坏名字.log', // 解析不了：不碰
      ]) {
        await File('${dir.path}/$name').writeAsString('x');
      }

      final removed = AppLog.pruneOldLogsIn(dir, now: now);
      expect(removed, 2);

      final left = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toSet();
      expect(left, {
        'app-2026-10-12.log',
        'app-2026-10-25.log',
        'server.log',
        'app-坏名字.log',
      });
    });

    test('文件名解析：合法日期返回 DateTime，非法/别的格式返回 null', () {
      expect(
        AppLog.logDateFromName('app-2026-10-25.log'),
        DateTime(2026, 10, 25),
      );
      expect(AppLog.logDateFromName('app-2026-13-40.log'), isNull);
      expect(AppLog.logDateFromName('app-2026-02-30.log'), isNull);
      expect(AppLog.logDateFromName('2026-10-25_09-27-24.log'), isNull);
      expect(AppLog.logDateFromName('app-2026-10-25.log.gz'), isNull);
    });

    test('保留天数可配置，传 1 天时只留今天', () {
      final now = DateTime(2026, 10, 25);
      expect(
        AppLog.shouldDeleteLog('app-2026-10-24.log', now, keepDays: 1),
        isTrue,
      );
      expect(
        AppLog.shouldDeleteLog('app-2026-10-25.log', now, keepDays: 1),
        isFalse,
      );
    });
  });
}
