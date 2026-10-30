import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_info.dart';
import 'logger.dart';

/// 这台设备（这个安装实例）的身份。
///
/// 不能拿 `child_id`（同一宝宝可多台设备）或全站共享的 `API_TOKEN`
/// （所有设备一样）来区分客户端。这里的规则：
///
/// 1. 优先用系统 `ANDROID_ID` 派生 → `a_<16 位 hex>`。
///    同一签名 + 同一用户下**卸载重装不变**（恢复出厂 / 换签名才会变）；
///    IMEI 从 Android 10 起拿不到，不能当标识。
/// 2. 拿不到（iOS、模拟器、通道异常）→ 首次启动随机生成 `c_<32 位 hex>`，
///    存本地复用；这种情况卸载重装会变，属已知限制。
class ClientIdentity {
  static const String _prefsKey = 'client_id';
  static String? _cached;
  static String? _appVersion;
  static String? _label;

  /// 形如 `a_1a2b3c4d5e6f7a8b` 或 `c_...`；只含安全字符，可直接当目录名。
  static Future<String> id() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);

    final hardwareID = _fromAndroidID(await DeviceInfo.androidId());
    if (hardwareID != null) {
      if (saved != hardwareID) {
        // 老版本用的是随机 id，这里迁到设备派生 id（只会发生一次）
        AppLog.i('app', 'client_id 迁移为设备标识 old=$saved new=$hardwareID');
        await prefs.setString(_prefsKey, hardwareID);
      }
      _cached = hardwareID;
      return hardwareID;
    }

    if (saved != null && saved.isNotEmpty) {
      _cached = saved;
      return saved;
    }

    final id = 'c_${_randomHex(16)}';
    await prefs.setString(_prefsKey, id);
    _cached = id;
    return id;
  }

  /// 设备可读名，例如 `vivo V2025A · Android 15`，方便在设备列表里认手机。
  static Future<String> label() async {
    final cached = _label;
    if (cached != null) return cached;

    final name = await DeviceInfo.displayName();
    final os = await DeviceInfo.osName();
    final parts = [if (name.isNotEmpty) name, if (os.isNotEmpty) os];
    final out = parts.isEmpty
        ? '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'
              .trim()
        : parts.join(' · ');
    _label = out;
    return out;
  }

  static String get platform => Platform.operatingSystem;

  /// App 版本（带构建号），服务端排查问题用。
  static Future<String> appVersion() async {
    final cached = _appVersion;
    if (cached != null) return cached;
    try {
      final pkg = await PackageInfo.fromPlatform();
      final v = '${pkg.version} (${pkg.buildNumber})';
      _appVersion = v;
      return v;
    } catch (_) {
      return '';
    }
  }

  /// ANDROID_ID 是 16 位十六进制；太短 / 空 / 全 0 视为不可用（模拟器常见）。
  static String? _fromAndroidID(String raw) {
    final hex = raw.toLowerCase().replaceAll(RegExp('[^0-9a-f]'), '');
    if (hex.length < 8) return null;
    if (hex.replaceAll('0', '').isEmpty) return null;
    return 'a_$hex';
  }

  /// 仅测试用：清掉内存缓存（SharedPreferences 里的值不动）。
  @visibleForTesting
  static void debugResetCache() {
    _cached = null;
    _appVersion = null;
    _label = null;
  }

  static String _randomHex(int bytes) {
    final rnd = Random.secure();
    final buf = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      buf.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }
}
