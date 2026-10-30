import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../models/app_update.dart';
import 'api_client.dart';
import 'app_updater.dart';
import 'client_commands.dart';
import 'client_identity.dart';
import 'logger.dart';

/// 客户端心跳：每 30 秒跟服务端对一次，做三件事——
///
/// 1. 上报本次对话运行的**累计时长**（服务端按 run_id 取 max，重复/乱序上报幂等）；
/// 2. 领取服务端下发的指令（如「提取客户端日志」）；
/// 3. 接收「有新版本」通知（亮红点 + Toast，不自动更新）；
/// 4. 刷新设备信息（label / 版本 / 最后活跃时间，多台设备按 client_id 隔离）。
///
/// 只在 App 前台跑：退到后台停表，回到前台立刻补一次。
/// 这样即使进程被系统杀掉，最多只丢最后一个 30 秒。
class Heartbeat {
  static const Duration interval = Duration(seconds: 30);

  static final ApiClient _api = ApiClient();
  static final Random _rnd = Random();

  static Timer? _timer;
  static _LifecycleWatcher? _watcher;
  static bool _started = false;
  static bool _beating = false;

  /// 当前对话运行；没在对话页时为空（心跳照跑，只为领指令）。
  static String? _childId;
  static String? _sessionId;
  static String? _runId;
  static DateTime? _startedAt;

  /// App 启动时调用一次（幂等）。需要 `WidgetsFlutterBinding.ensureInitialized()`。
  static Future<void> start() async {
    if (_started) return;
    _started = true;
    _watcher ??= _LifecycleWatcher();
    WidgetsBinding.instance.addObserver(_watcher!);
    // 提前生成 client_id，别让首次心跳和日志上传抢着生成；
    // 本地存储异常也不能影响启动（心跳失败只是少一点统计精度）
    try {
      await ClientIdentity.id();
    } catch (e) {
      AppLog.w('hb', '生成 client_id 失败: $e');
    }
    _startTimer();
    unawaited(beatNow());
  }

  /// 进入对话页：开始计时并立刻上报一次（服务端由此记 1 次打开）。
  static void startSession({
    required String childId,
    required String sessionId,
  }) {
    _childId = childId;
    _sessionId = sessionId;
    _startedAt = DateTime.now();
    _runId =
        'run_${_startedAt!.millisecondsSinceEpoch}_'
        '${_rnd.nextInt(1 << 32).toRadixString(16)}';
    AppLog.i('hb', '开始计时 run=$_runId child=$childId');
    unawaited(beatNow());
  }

  /// 结束 / 退出对话：补一次最终时长后停止计时（幂等，重复调用无副作用）。
  static Future<void> finishSession() async {
    if (_runId == null) return;
    await beatNow();
    _childId = null;
    _sessionId = null;
    _runId = null;
    _startedAt = null;
  }

  /// 立即心跳一次（生命周期恢复、结束对话时用）。
  static Future<void> beatNow() async {
    if (_beating) return;
    _beating = true;
    try {
      final clientId = await ClientIdentity.id();
      final session = _sessionSnapshot();
      final resp = await _api.heartbeat({
        'client_id': clientId,
        'label': await ClientIdentity.label(),
        'platform': ClientIdentity.platform,
        'app_version': await ClientIdentity.appVersion(),
        // 服务端按 versionCode 判断要不要下发新版本通知
        'version_code': await AppUpdater.currentVersionCode(),
        'session': ?session,
      });

      final raw = resp['commands'];
      if (raw is List && raw.isNotEmpty) {
        final commands = raw
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(growable: false);
        if (commands.isNotEmpty) {
          AppLog.i('hb', '收到 ${commands.length} 条服务端指令');
          unawaited(ClientCommands.run(commands));
        }
      }

      // 服务端有新版本：亮红点 + 弹一次 Toast，由家长自己决定什么时候更新
      final update = resp['app_update'];
      if (update is Map) {
        await AppUpdater.onServerUpdate(
          AppUpdate.fromJson(update.cast<String, dynamic>()),
        );
      }
    } catch (e) {
      // 没网 / 服务端重启都不影响宝宝使用，下个周期自动重试
      AppLog.w('hb', '心跳失败（下个周期重试）: $e');
    } finally {
      _beating = false;
    }
  }

  static Map<String, dynamic>? _sessionSnapshot() {
    final startedAt = _startedAt;
    final runId = _runId;
    if (startedAt == null || runId == null) return null;
    return {
      'child_id': _childId ?? '',
      'session_id': _sessionId ?? '',
      'run_id': runId,
      'duration_sec': DateTime.now().difference(startedAt).inSeconds,
    };
  }

  static void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(beatNow()));
  }

  static void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// 前台才跑心跳，后台停表省电。
  static void _onForeground() {
    _startTimer();
    unawaited(beatNow());
  }

  static void _onBackground() => _stopTimer();
}

class _LifecycleWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      Heartbeat._onForeground();
    } else {
      Heartbeat._onBackground();
    }
  }
}
