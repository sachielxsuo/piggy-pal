import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 设备硬件信息（Android 原生通道）。
///
/// 用来生成稳定的设备标识和可读名字：
/// - `android_id`：Settings.Secure.ANDROID_ID，同一签名 + 同一用户下
///   卸载重装不变（恢复出厂才会变）。IMEI 从 Android 10 起普通应用拿不到，
///   不能用来做标识。
/// - `manufacturer` / `model`：给设备列表看，知道是哪台手机。
///
/// 非 Android（或通道不可用）时全为空，调用方自行降级。
class DeviceInfo {
  static const MethodChannel _channel = MethodChannel('piggy_pal/device');
  static Map<String, dynamic>? _cached;

  static Future<Map<String, dynamic>> read() async {
    final cached = _cached;
    if (cached != null) return cached;

    var out = <String, dynamic>{};
    try {
      final raw = await _channel.invokeMethod<Map>('deviceInfo');
      if (raw != null) {
        out = raw.map((k, v) => MapEntry(k.toString(), v));
      }
    } on PlatformException catch (e) {
      debugPrint('读取设备信息失败: ${e.message}');
    } on MissingPluginException {
      // iOS / 单元测试没有这个通道，走随机 id 兜底
    }
    _cached = out;
    return out;
  }

  /// 16 位十六进制的 ANDROID_ID；拿不到时为空串。
  static Future<String> androidId() async {
    final v = (await read())['android_id']?.toString() ?? '';
    return v.toLowerCase();
  }

  /// 可读设备名，如 `vivo V2025A`；拿不到时返回空串。
  static Future<String> displayName() async {
    final m = await read();
    final brand = (m['manufacturer'] ?? '').toString().trim();
    final model = (m['model'] ?? '').toString().trim();
    if (brand.isEmpty && model.isEmpty) return '';
    if (model.toLowerCase().startsWith(brand.toLowerCase())) return model;
    return '$brand $model'.trim();
  }

  /// 系统版本，如 `Android 15`；拿不到时返回空串。
  static Future<String> osName() async {
    final m = await read();
    final ver = (m['os_version'] ?? '').toString().trim();
    if (ver.isEmpty) return '';
    return 'Android $ver';
  }

  @visibleForTesting
  static void debugResetCache() => _cached = null;
}
