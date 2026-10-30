import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'logger.dart';

/// 轻提示。优先用 Android 原生 Toast（不打断操作、不占页面），
/// 非 Android / 单测环境降级为 SnackBar。
///
/// 用在「发现新版本」这类不需要家长立刻处理的提示上——Toast 只提示一下，
/// 不会像对话框那样挡住宝宝正在玩的页面。
class AppToast {
  static const MethodChannel _channel = MethodChannel('piggy_pal/ui');

  /// SnackBar 兜底需要一个根 Navigator；在 [MaterialApp] 上挂它。
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static Future<void> show(String text) async {
    if (text.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('showToast', {
        'text': text,
        'long': true,
      });
      return;
    } on MissingPluginException {
      // iOS / 单元测试没有原生通道，走 SnackBar
    } on PlatformException catch (e) {
      AppLog.w('ui', '原生 Toast 失败: ${e.message}');
    }
    _snack(text);
  }

  static void _snack(String text) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 4)),
    );
  }
}
