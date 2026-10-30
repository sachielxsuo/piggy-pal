import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';
import '../models/app_update.dart';
import 'app_toast.dart';
import 'client_identity.dart';
import 'logger.dart';

/// 安装 APK 的结果。
enum InstallOutcome {
  /// 已拉起系统安装器（宝宝 / 家长确认后完成安装）。
  started,

  /// 还没允许「安装未知应用」：原生侧已打开设置页，授权后返回可重试。
  permissionRequired,

  /// 安装包丢失 / 系统拒绝。
  failed,
}

/// 客户端自动更新：检查版本 → 下载 APK → 校验 → 拉起系统安装器。
///
/// 增量（差分包）需要为每个历史版本生成补丁、在端上做二进制合并，还要处理
/// 签名与 ABI 差异，出错就是装不上；当前包约 20MB，全量下载更稳，所以统一全量。
class AppUpdater {
  static const MethodChannel _installer = MethodChannel('piggy_pal/installer');

  static final Dio _dio = Dio(
    BaseOptions(
      baseUrl: Env.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 10),
      headers: {if (Env.apiToken.isNotEmpty) 'X-API-Token': Env.apiToken},
    ),
  );

  /// 已下载完但还没装上的包：用户去开「安装未知应用」权限，返回后自动重试。
  static File? _pendingInstall;

  static bool _clientHeaderAdded = false;

  /// 更新检查 / 下载也要带 client_id，服务端日志才能对上设备。
  static void _ensureClientHeader() {
    if (_clientHeaderAdded) return;
    _clientHeaderAdded = true;
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            options.headers['X-Client-Id'] = await ClientIdentity.id();
          } catch (_) {
            // 日志少一列，不影响更新
          }
          handler.next(options);
        },
      ),
    );
  }

  /// 静默检查发现的可用更新；UI 监听它来决定要不要显示红点。
  /// null 表示没有更新（或还没检查过）。
  static final AppUpdateNotifier availableUpdate = AppUpdateNotifier();

  /// 本地记录「已经看过哪一版」，避免每次启动红点又冒出来。
  static const String _seenKey = 'seen_update_code';

  /// 本地记录「已经用 Toast 提示过哪一版」，同一个版本只提示一次。
  static const String _toastKey = 'update_toast_code';

  /// 低于最低版本时非空：ForceUpdateGate 监听它，弹不可关闭的强制更新窗。
  static final ValueNotifier<AppUpdate?> forceUpdate = ValueNotifier<AppUpdate?>(
    null,
  );

  /// 当前是否已知有新版本（给红点判断用）。
  static bool get hasUpdate => availableUpdate.value != null;

  /// 是否还有「没看过」的新版本（一级入口 / 抽屉红点都看它）。
  static bool get hasBadge => availableUpdate.badge.value;

  /// 当前安装包版本，如 `v1.0.2`。
  ///
  /// 默认只给 versionName；开发者模式下才带上 versionCode（`v1.0.2 (3)`），
  /// 家长不需要看到构建号。
  static Future<String> currentVersionLabel({bool withBuild = false}) async {
    final pkg = await PackageInfo.fromPlatform();
    return withBuild
        ? 'v${pkg.version} (${pkg.buildNumber})'
        : 'v${pkg.version}';
  }

  static Future<int> currentVersionCode() async {
    final pkg = await PackageInfo.fromPlatform();
    return int.tryParse(pkg.buildNumber) ?? 0;
  }

  /// 检查服务端是否有更新；已是最新返回 null。
  /// 结果同时写进 [availableUpdate]，界面据此显示 / 隐藏红点。
  static Future<AppUpdate?> check() async {
    _ensureClientHeader();
    final resp = await _dio.get('/app/latest');
    final update = AppUpdate.fromJson(
      (resp.data as Map).cast<String, dynamic>(),
    );
    if (update.versionCode <= 0 || update.apkUrl.isEmpty) {
      availableUpdate.value = null;
      return null;
    }
    final current = await currentVersionCode();
    _applyMinVersion(update, current);
    if (update.versionCode <= current) {
      AppLog.i(
        'update',
        '已是最新版本 current=$current server=${update.versionCode}',
      );
      availableUpdate.value = null;
      return null;
    }
    AppLog.i(
      'update',
      '发现新版本 ${update.versionName}(${update.versionCode}) '
          'current=$current size=${update.size}',
    );
    availableUpdate.value = update;
    return update;
  }

  /// 启动时静默检查：只更新红点状态，不弹任何窗、不打断宝宝。
  /// 真正更新由家长在「关于 → 检查更新」里手动触发。
  static Future<AppUpdate?> checkSilently() async {
    try {
      return await check();
    } catch (e) {
      // 没网 / 服务端没发布过版本都不打扰用户
      AppLog.i('update', '静默检查更新失败（忽略）: $e');
      return null;
    }
  }

  /// App 启动时恢复「已经看过哪一版」，重开 App 不再重复亮红点。
  static Future<void> restoreSeen() async {
    try {
      await availableUpdate.loadSeen();
    } catch (e) {
      AppLog.w('update', '读取已看过版本失败: $e');
    }
  }

  /// 用户已经看到新版本提示（进入「关于」）：内外红点一起消掉，
  /// 但保留版本信息，页面里的「发现新版本」文案和更新入口不受影响。
  static Future<void> markSeen() async {
    try {
      await availableUpdate.markSeen();
    } catch (e) {
      AppLog.w('update', '记录已看过版本失败: $e');
    }
  }

  /// 心跳带回服务端的新版本通知：亮红点 + 弹一次 Toast（每个版本只弹一次）。
  ///
  /// 不做自动更新，也不弹对话框——家长看到提示后自己点「关于 → 检查更新」。
  static Future<void> onServerUpdate(AppUpdate update) async {
    if (update.versionCode <= 0 || update.apkUrl.isEmpty) return;
    var current = 0;
    try {
      current = await currentVersionCode();
    } catch (e) {
      AppLog.w('update', '读取当前版本号失败: $e');
    }
    // 先判断最低版本：即使当前已经是最新版（理论上不会低于 min），也不会漏判
    if (current > 0) _applyMinVersion(update, current);
    if (update.versionCode <= current) {
      // 已经装上了（比如刚更新完），清掉旧提示
      if (availableUpdate.value != null) availableUpdate.value = null;
      return;
    }

    final alreadyKnown =
        availableUpdate.value?.versionCode == update.versionCode;
    availableUpdate.value = update;
    AppLog.i('update', '服务端通知新版本 ${update.versionName}(${update.versionCode})');
    if (!alreadyKnown) await _toastOnce(update);
  }

  /// 最低版本判定：低于 min 就置位 [forceUpdate]，由 ForceUpdateGate 弹强制更新窗。
  /// 服务端把 min 夹在 [0, latest] 之间，所以这里拿到的值最多要求「更新到最新版」。
  static void _applyMinVersion(AppUpdate update, int current) {
    if (update.forcesUpdateFor(current)) {
      if (forceUpdate.value?.versionCode != update.versionCode) {
        AppLog.w(
          'update',
          '当前 versionCode=$current 低于最低版本 ${update.minVersionCode}，'
              '需要强制更新到 ${update.versionName}(${update.versionCode})',
        );
      }
      forceUpdate.value = update;
      return;
    }
    if (forceUpdate.value != null) forceUpdate.value = null;
  }

  /// 仅测试用：清空强制更新状态。
  @visibleForTesting
  static void debugResetForce() {
    forceUpdate.value = null;
  }

  /// 同一个版本只 Toast 一次，避免每 30 秒心跳都弹。
  static Future<void> _toastOnce(AppUpdate update) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toasted = prefs.getInt(_toastKey) ?? 0;
      if (update.versionCode <= toasted) return;
      await prefs.setInt(_toastKey, update.versionCode);
    } catch (e) {
      // 本地存储异常时仍然提示，只是可能重复
      AppLog.w('update', '记录更新提示失败: $e');
    }
    await AppToast.show('发现新版本 v${update.versionName}，家长可在「关于」里更新');
  }

  /// 全量下载到缓存目录，带进度；已下完且大小一致的文件直接复用。
  static Future<File> download(
    AppUpdate update, {
    void Function(double progress)? onProgress,
  }) async {
    _ensureClientHeader();
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/updates');
    await dir.create(recursive: true);

    // 清掉旧版本安装包，避免缓存越积越大
    final keepName = 'piggy-pal-${update.versionCode}.apk';
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.apk') && !e.path.endsWith(keepName)) {
        try {
          await e.delete();
        } catch (_) {
          // 清理失败不影响本次更新
        }
      }
    }

    final file = File('${dir.path}/$keepName');
    final usable =
        await file.exists() &&
        update.size > 0 &&
        await file.length() == update.size;
    if (!usable) {
      AppLog.i('update', '开始下载 ${update.apkUrl} size=${update.size}');
      await _dio.download(
        update.apkUrl,
        file.path,
        deleteOnError: true,
        onReceiveProgress: (received, total) {
          final all = total > 0 ? total : update.size;
          if (all > 0) {
            onProgress?.call((received / all).clamp(0.0, 1.0));
          }
        },
      );
      AppLog.i('update', '下载完成 size=${await file.length()}');
    } else {
      AppLog.i('update', '复用已下载的安装包 size=${update.size}');
      onProgress?.call(1);
    }

    if (update.size > 0 && await file.length() != update.size) {
      try {
        await file.delete();
      } catch (_) {}
      throw Exception('安装包大小不一致');
    }
    if (update.sha256.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != update.sha256.toLowerCase()) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception('安装包校验失败');
      }
    }
    return file;
  }

  /// 拉起系统安装器。Android 不允许静默安装，最后一步由用户确认。
  ///
  /// `openSettings` 为 true 时，缺少「安装未知应用」权限会自动打开设置页；
  /// 自动重试传 false，避免用户从设置页返回后又被弹回去。
  static Future<InstallOutcome> install(
    File apk, {
    bool openSettings = true,
  }) async {
    _pendingInstall = apk;
    try {
      final result = await _installer.invokeMethod<String>('installApk', {
        'path': apk.path,
        'openSettings': openSettings,
      });
      switch (result) {
        case 'started':
          _pendingInstall = null;
          AppLog.i('update', '已拉起系统安装器');
          return InstallOutcome.started;
        case 'permission_required':
          AppLog.w('update', '缺少「安装未知应用」权限');
          return InstallOutcome.permissionRequired;
        case 'missing':
          _pendingInstall = null;
          AppLog.w('update', '安装包不存在: ${apk.path}');
          return InstallOutcome.failed;
        default:
          _pendingInstall = null;
          AppLog.w('update', '安装未开始: $result');
          return InstallOutcome.failed;
      }
    } on PlatformException catch (e) {
      AppLog.e('update', '拉起安装器失败: ${e.message}');
      _pendingInstall = null;
      return InstallOutcome.failed;
    } on MissingPluginException catch (e) {
      AppLog.e('update', '安装通道未注册: $e');
      _pendingInstall = null;
      return InstallOutcome.failed;
    }
  }

  /// 去系统设置里允许「安装未知应用」。
  static Future<void> openInstallSettings() async {
    try {
      await _installer.invokeMethod<bool>('openInstallSettings');
    } on PlatformException catch (e) {
      AppLog.w('update', '打开安装权限设置失败: ${e.message}');
    } on MissingPluginException catch (e) {
      AppLog.w('update', '安装通道未注册: $e');
    }
  }

  /// 用户去开完权限回到 App：自动把刚才下载好的包再交给安装器。
  /// 只尝试拉起安装，不再自动跳设置页，避免来回来去。
  static Future<InstallOutcome?> retryPendingInstall() async {
    final apk = _pendingInstall;
    if (apk == null || !await apk.exists()) return null;
    return install(apk, openSettings: false);
  }
}

/// 「有新版本」状态：版本信息 + 红点是否还没被看过。
///
/// 红点和版本信息要分开：红点只负责提醒一次（进过「关于」就消），
/// 而「关于」页里「发现新版本 vX」的文案要一直保留到真的更新完。
class AppUpdateNotifier extends ValueNotifier<AppUpdate?> {
  AppUpdateNotifier() : super(null);

  /// 用户已经看过提示的最高 versionCode；比它新的才亮红点。
  int _seenCode = 0;

  /// 是否还有没看过的新版本。首页三横线、抽屉「关于」、家长中心「关于」
  /// 都监听它，所以内外红点永远同步。
  final ValueNotifier<bool> badge = ValueNotifier<bool>(false);

  @override
  set value(AppUpdate? next) {
    super.value = next;
    _syncBadge();
  }

  void _syncBadge() {
    final code = value?.versionCode ?? 0;
    badge.value = code > 0 && code > _seenCode;
  }

  /// 启动时恢复「已看过」的版本号。
  Future<void> loadSeen() async {
    final prefs = await SharedPreferences.getInstance();
    _seenCode = prefs.getInt(AppUpdater._seenKey) ?? 0;
    _syncBadge();
  }

  /// 用户看过了：记下这一版，内外红点全部熄灭（版本信息保留）。
  Future<void> markSeen() async {
    final code = value?.versionCode ?? 0;
    if (code > _seenCode) {
      _seenCode = code;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(AppUpdater._seenKey, code);
    }
    badge.value = false;
  }

  /// 仅测试用：清空内存状态。
  @visibleForTesting
  void debugReset() {
    super.value = null;
    _seenCode = 0;
    badge.value = false;
  }
}
