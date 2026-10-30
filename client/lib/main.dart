import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config/env.dart';
import 'pages/home_page.dart';
import 'services/app_toast.dart';
import 'services/app_updater.dart';
import 'services/heartbeat.dart';
import 'services/logger.dart';
import 'widgets/force_update_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 仅 debug 且配置了 whistle 代理时，让所有 HTTP 请求走代理
  // （Flutter 的 dart:io HttpClient 默认不读系统代理，需显式指定）
  if (kDebugMode && Env.whistleProxy.isNotEmpty) {
    HttpOverrides.global = _WhistleProxy(Env.whistleProxy);
  }

  // 初始化日志落盘（debug/release 都落文件），失败也不阻断启动
  await AppLog.init();

  // 启动日志：出问题时第一眼看版本 / 服务地址 / token 是否注入
  AppLog.i(
    'app',
    '启动 ${kReleaseMode ? 'release' : 'debug'} · 服务 ${Env.apiBaseUrl}'
        ' · token ${Env.apiToken.isEmpty ? '未注入' : '已注入'}'
        ' · 日志目录 ${AppLog.dirPath.isEmpty ? '不可用' : AppLog.dirPath}',
  );

  // 恢复「已经看过哪一版」，重开 App 不重复亮红点
  await AppUpdater.restoreSeen();

  // 30 秒心跳：上报陪伴时长、领取服务端指令 / 新版本通知（只在前后台切换时停/启）
  unawaited(Heartbeat.start());

  // 兜底捕获未处理异常并写入本地日志，release 真机也能回溯
  FlutterError.onError = (details) {
    AppLog.e(
      'app',
      '未处理的 UI 异常: ${details.exceptionAsString()}\n${details.stack}',
    );
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.e('app', '未处理的异步异常: $error\n$stack');
    // 已记录，不再让 App 因未捕获异常退出
    return true;
  };

  // 小朋友使用场景固定竖屏，避免误旋转导致布局错位
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  runApp(const PiggyPalApp());
}

/// debug 专用：把 dart:io 请求导向 whistle 代理，并放行代理证书。
class _WhistleProxy extends HttpOverrides {
  final String proxy;

  _WhistleProxy(this.proxy);

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) => 'PROXY $proxy';
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}

class PiggyPalApp extends StatelessWidget {
  const PiggyPalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PiggyPal 小猪玩伴',
      // 原生 Toast 不可用时（iOS / 测试）用 SnackBar 兜底，需要一个根 Navigator
      navigatorKey: AppToast.navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3B82F6)),
        useMaterial3: true,
      ),
      home: const ForceUpdateGate(child: HomePage()),
    );
  }
}
