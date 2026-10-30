import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 全 App 统一日志。
///
/// - debug：同时输出到控制台（`dart:developer.log`）+ 追加写入本地文件
/// - release：仅追加写入本地文件（控制台关闭，避免 logcat 刷屏）
///
/// 文件路径：`<外部专属目录>/logs/app-YYYY-MM-DD.log`
///   Android = `/storage/emulated/0/Android/data/com.piggypal.piggy_pal/files/logs/`
///   查看：`adb pull /sdcard/Android/data/com.piggypal.piggy_pal/files/logs/ ./`
///
/// 跨过零点会自动切到新文件（不是只在启动时算一次日期），
/// 并且只保留最近 [keepLogDays] 天，避免设备上日志无限增长。
class AppLog {
  /// 本地日志保留天数（含今天）。
  static const int keepLogDays = 14;

  static const int _levelDebug = 0;
  static const int _levelInfo = 500;
  static const int _levelWarn = 900;
  static const int _levelError = 1000;

  static final List<String> _buffer = [];
  static Directory? _dir;
  static File? _file;

  /// 当前 [_file] 对应的日期（`YYYY-MM-DD`）；和今天不一致就切文件。
  static String _fileDate = '';
  static Future<void> _chain = Future.value();
  static bool _ready = false;

  static void d(String tag, String msg) => _log('D', tag, msg);
  static void i(String tag, String msg) => _log('I', tag, msg);
  static void w(String tag, String msg) => _log('W', tag, msg);
  static void e(String tag, String msg) => _log('E', tag, msg);

  /// 初始化日志文件。须在 `WidgetsFlutterBinding.ensureInitialized()` 之后调用。
  /// 会创建日志目录并确定当天日志文件；init 之前的日志先入内存缓冲，init 后统一落盘。
  static Future<void> init() async {
    if (_ready) return;
    try {
      Directory? dir;
      try {
        dir = await getExternalStorageDirectory();
      } catch (_) {
        dir = null;
      }
      // 外部专属目录不可用时回退到应用私有文档目录（仍落盘，只是 adb 需 root 才能拿）
      dir ??= await getApplicationDocumentsDirectory();

      final sub = Directory('${dir.path}/logs');
      if (!await sub.exists()) await sub.create(recursive: true);
      _dir = sub;
      _openTodayFile();
      _ready = true;
      // App 可能很久没打开：启动时先清掉过期日志
      _pruneOldLogs();
    } catch (_) {
      // 拿不到目录也不崩，仅降级为不落盘
      _ready = false;
    }
    await _flushNow();
  }

  static void _log(String level, String tag, String msg) {
    if (!kReleaseMode) {
      int lvl;
      switch (level) {
        case 'D':
          lvl = _levelDebug;
          break;
        case 'W':
          lvl = _levelWarn;
          break;
        case 'E':
          lvl = _levelError;
          break;
        default:
          lvl = _levelInfo;
      }
      developer.log(msg, name: tag, level: lvl);
    }

    _buffer.add('${_now()} [$level] $tag: $msg');
    _scheduleFlush();
  }

  /// 串行写盘：多日志并发时用 Future 链保证 append 顺序不乱。
  static void _scheduleFlush() {
    _chain = _chain.then((_) => _flushNow());
  }

  static Future<void> _flushNow() async {
    if (!_ready) return;
    // 跨过零点后写到新的 app-YYYY-MM-DD.log，而不是继续追加到昨天的文件
    _rolloverIfNeeded();
    final f = _file;
    if (f == null) return;
    final batch = List<String>.from(_buffer);
    _buffer.clear();
    if (batch.isEmpty) return;
    try {
      await f.writeAsString(
        '${batch.join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 写盘失败静默忽略，不影响业务
    }
  }

  /// 指向「今天」的日志文件。
  static void _openTodayFile() {
    final dir = _dir;
    if (dir == null) return;
    _fileDate = _dateStr();
    _file = File('${dir.path}/app-$_fileDate.log');
  }

  /// 日期变了就切文件，并把超过保留期的日志删掉。
  static void _rolloverIfNeeded() {
    if (_dir == null || _dateStr() == _fileDate) return;
    _openTodayFile();
    _pruneOldLogs();
  }

  /// 删除超过 [keepLogDays] 天的日志（只动 `app-YYYY-MM-DD.log`，别的文件不碰）。
  static void _pruneOldLogs() {
    final dir = _dir;
    if (dir == null) return;
    try {
      pruneOldLogsIn(dir);
    } catch (_) {
      // 清理失败不影响写日志
    }
  }

  /// 实际清理逻辑，抽出来便于单测（不依赖 path_provider）。
  /// 返回删除的文件数。
  @visibleForTesting
  static int pruneOldLogsIn(
    Directory dir, {
    DateTime? now,
    int keepDays = keepLogDays,
  }) {
    final at = now ?? DateTime.now();
    var removed = 0;
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.isEmpty ? '' : f.uri.pathSegments.last;
      if (!shouldDeleteLog(name, at, keepDays: keepDays)) continue;
      try {
        f.deleteSync();
        removed++;
      } catch (_) {
        // 单个文件删不掉就跳过
      }
    }
    return removed;
  }

  /// 从 `app-YYYY-MM-DD.log` 解析日期；不是这种文件名返回 null。
  @visibleForTesting
  static DateTime? logDateFromName(String name) {
    final m = _logNameRe.firstMatch(name);
    if (m == null) return null;
    final y = int.parse(m[1]!);
    final mo = int.parse(m[2]!);
    final d = int.parse(m[3]!);
    final dt = DateTime(y, mo, d);
    // 拒绝 2026-13-40 这类被 DateTime 自动进位的非法日期
    if (dt.year != y || dt.month != mo || dt.day != d) return null;
    return dt;
  }

  /// [name] 是否已超过保留期（今天算第 1 天）。
  @visibleForTesting
  static bool shouldDeleteLog(
    String name,
    DateTime now, {
    int keepDays = keepLogDays,
  }) {
    final day = logDateFromName(name);
    if (day == null) return false;
    final today = DateTime(now.year, now.month, now.day);
    final cutoff = today.subtract(Duration(days: keepDays - 1));
    return day.isBefore(cutoff);
  }

  /// 日志目录绝对路径（未初始化或取不到时为空字符串）。
  static String get dirPath => _dir?.path ?? '';

  /// 立即把内存里的日志落盘。导出 / 复制日志前调用，避免最后几行还没写进去。
  static Future<void> flush() async {
    await _chain;
    await _flushNow();
  }

  /// 最近 [maxLines] 行日志，供「关于 → 运行日志」一键复制。
  ///
  /// 只取尾部，排查问题看最近的上下文就够了，日志文件很大时也不会卡界面。
  static Future<String> recent({int maxLines = 500}) async {
    await flush();
    final all = await readAll();
    if (all.isEmpty) return '';
    final lines = all
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.length <= maxLines) return lines.join('\n');
    return lines.sublist(lines.length - maxLines).join('\n');
  }

  /// 截取最近 [window] 时间内的日志（默认 2 小时），用于上传到服务端。
  ///
  /// 多行堆栈会跟随它所属日志条目的时间一起保留，不会被时间过滤切碎。
  static Future<LogExcerpt> excerpt({
    Duration window = const Duration(hours: 2),
  }) async {
    await flush();
    final all = await readAll();
    if (all.isEmpty) return const LogExcerpt(text: '');
    return excerptFrom(all, window: window);
  }

  /// 纯函数版日志截取，便于单测（不读文件）。
  @visibleForTesting
  static LogExcerpt excerptFrom(
    String all, {
    Duration window = const Duration(hours: 2),
    DateTime? now,
  }) {
    final cutoff = (now ?? DateTime.now()).subtract(window);
    final buf = StringBuffer();
    DateTime? start;
    DateTime? current;
    var count = 0;

    for (final raw in all.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) continue;
      final ts = _parseTimestamp(line);
      if (ts != null) current = ts;
      // current == null：文件开头的续行，没有归属，跳过
      if (current == null || current.isBefore(cutoff)) continue;
      buf.writeln(line);
      count++;
      start ??= current;
    }

    return LogExcerpt(text: buf.toString(), start: start, lineCount: count);
  }

  /// 读取全部日志（合并 logs 目录下所有 .log 文件，按文件名排序，供 App 内查看/导出）。
  static Future<String> readAll() async {
    final dir = _dir;
    if (dir == null) return '';
    try {
      final files =
          dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.log'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final buf = StringBuffer();
      for (final f in files) {
        final content = await f.readAsString();
        if (content.isNotEmpty) buf.writeln(content);
      }
      return buf.toString();
    } catch (_) {
      return '';
    }
  }

  static String _now() {
    final t = DateTime.now();
    return '${_date(t)} ${_pad(t.hour)}:${_pad(t.minute)}:${_pad(t.second)}'
        '.${t.millisecond.toString().padLeft(3, '0')}';
  }

  static String _dateStr() => _date(DateTime.now());

  static String _date(DateTime t) =>
      '${t.year}-${_pad(t.month)}-${_pad(t.day)}';

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static final RegExp _logNameRe = RegExp(
    r'^app-(\d{4})-(\d{2})-(\d{2})\.log$',
  );

  static final RegExp _stampRe = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})',
  );

  /// 解析行首的 `2026-10-25 11:27:24.204`，失败返回 null（堆栈等续行）。
  static DateTime? _parseTimestamp(String line) {
    final m = _stampRe.firstMatch(line);
    if (m == null) return null;
    return DateTime.tryParse('${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}');
  }
}

/// 最近一段时间内的日志切片，上传时作为文件名与内容来源。
class LogExcerpt {
  final String text;

  /// 切片中最早一条日志的时间；没有日志时为 null。
  final DateTime? start;
  final int lineCount;

  const LogExcerpt({required this.text, this.start, this.lineCount = 0});

  bool get isEmpty => text.trim().isEmpty;

  /// 文件名 = 日志起始时间，例如 `2026-10-25_09-27-24.log`。
  String get fileName {
    final s = start;
    if (s == null) return 'unknown.log';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${s.year}-${two(s.month)}-${two(s.day)}_'
        '${two(s.hour)}-${two(s.minute)}-${two(s.second)}.log';
  }
}
