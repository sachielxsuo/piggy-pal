import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggy_pal/models/app_update.dart';
import 'package:piggy_pal/services/app_updater.dart';
import 'package:piggy_pal/widgets/update_badge.dart';

const _newVersion = AppUpdate(
  versionCode: 3,
  versionName: '1.0.2',
  apkUrl: '/app/download/piggy-pal-1.0.2-3.apk',
  size: 22020096,
  sha256: 'abc',
  changelog: '支持静默检查更新',
  force: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppUpdate 版本信息', () {
    test('fromJson 解析服务端 latest.json', () {
      final u = AppUpdate.fromJson({
        'version_code': 3,
        'version_name': '1.0.2',
        'apk_url': '/app/download/piggy-pal-1.0.2-3.apk',
        'size': 22020096,
        'sha256': 'ABCDEF',
        'changelog': '支持自动更新',
        'force': true,
      });
      expect(u.versionCode, 3);
      expect(u.versionName, '1.0.2');
      expect(u.apkUrl, '/app/download/piggy-pal-1.0.2-3.apk');
      expect(u.size, 22020096);
      expect(u.sha256, 'ABCDEF');
      expect(u.changelog, '支持自动更新');
      expect(u.force, isTrue);
      expect(u.sizeLabel, '21.0 MB');
    });

    test('缺省字段安全回退', () {
      final u = AppUpdate.fromJson({});
      expect(u.versionCode, 0);
      expect(u.apkUrl, '');
      expect(u.force, isFalse);
      expect(u.sizeLabel, '');
    });

    test('小于 1MB 时用 KB 展示', () {
      final u = AppUpdate.fromJson({'size': 512000});
      expect(u.sizeLabel, '500 KB');
    });

    test('解析最低版本号，缺省为 0（不强制）', () {
      expect(AppUpdate.fromJson({}).minVersionCode, 0);
      final u = AppUpdate.fromJson({'version_code': 20, 'min_version_code': 18});
      expect(u.minVersionCode, 18);
    });

    test('最低版本判定：0 / 当前版本未知 都不拦人', () {
      const noMin = AppUpdate(
        versionCode: 20,
        versionName: '1.0.20',
        apkUrl: '/x.apk',
        size: 1,
        sha256: '',
        changelog: '',
        force: false,
      );
      expect(noMin.forcesUpdateFor(18), isFalse);

      const withMin = AppUpdate(
        versionCode: 20,
        versionName: '1.0.20',
        apkUrl: '/x.apk',
        size: 1,
        sha256: '',
        changelog: '',
        force: true,
        minVersionCode: 18,
      );
      expect(withMin.forcesUpdateFor(17), isTrue);
      expect(withMin.forcesUpdateFor(18), isFalse, reason: '刚够最低版就放行');
      expect(withMin.forcesUpdateFor(19), isFalse);
      expect(withMin.forcesUpdateFor(0), isFalse, reason: '读不到包信息时不拦人');
    });
  });

  group('版本号展示', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'PiggyPal',
        packageName: 'com.piggypal.piggy_pal',
        version: '1.0.2',
        buildNumber: '3',
        buildSignature: '',
      );
    });

    test('默认只给家长看 versionName，不暴露构建号', () async {
      expect(await AppUpdater.currentVersionLabel(), 'v1.0.2');
    });

    test('开发者模式下才带 versionCode', () async {
      expect(
        await AppUpdater.currentVersionLabel(withBuild: true),
        'v1.0.2 (3)',
      );
    });
  });

  group('更新红点', () {
    tearDown(() => AppUpdater.availableUpdate.debugReset());

    testWidgets('有可用更新时显示红点，入口文字和箭头变红', (tester) async {
      AppUpdater.availableUpdate.value = _newVersion;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: UpdateBadge(child: Text('关于'))),
        ),
      );

      // 红点是一个带红底圆形的 Container
      final dots = tester.widgetList<Container>(find.byType(Container)).where((
        c,
      ) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.shape == BoxShape.circle &&
            d.color == const Color(0xFFEF4444);
      });
      expect(dots, isNotEmpty);
      expect(find.text('关于'), findsOneWidget);
    });

    testWidgets('没有更新时不显示红点，只留原图标', (tester) async {
      AppUpdater.availableUpdate.value = null;

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: UpdateBadge(child: Icon(Icons.chevron_right))),
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      final dots = tester.widgetList<Container>(find.byType(Container)).where((
        c,
      ) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.shape == BoxShape.circle &&
            d.color == const Color(0xFFEF4444);
      });
      expect(dots, isEmpty);
    });

    testWidgets('红点随状态实时变化，不需要重建页面', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: UpdateBadge(child: Text('关于'))),
        ),
      );
      expect(_redDotCount(tester), 0);

      AppUpdater.availableUpdate.value = _newVersion;
      await tester.pump();
      expect(_redDotCount(tester), 1);

      AppUpdater.availableUpdate.value = null;
      await tester.pump();
      expect(_redDotCount(tester), 0);
    });
  });

  group('最低版本（强制更新）', () {
    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'PiggyPal',
        packageName: 'com.piggypal.piggy_pal',
        version: '1.0.2',
        buildNumber: '3',
        buildSignature: '',
      );
      SharedPreferences.setMockInitialValues({});
      AppUpdater.availableUpdate.debugReset();
      AppUpdater.debugResetForce();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('piggy_pal/ui'), (
            call,
          ) async => true);
    });

    tearDown(() {
      AppUpdater.availableUpdate.debugReset();
      AppUpdater.debugResetForce();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('piggy_pal/ui'), null);
    });

    test('低于最低版本时置位 forceUpdate，心跳就能触发强制更新窗', () async {
      const forced = AppUpdate(
        versionCode: 20,
        versionName: '1.0.20',
        apkUrl: '/app/download/piggy-pal-1.0.20-20.apk',
        size: 21500000,
        sha256: 'abc',
        changelog: '协议升级',
        force: true,
        minVersionCode: 19,
      );
      await AppUpdater.onServerUpdate(forced);
      expect(AppUpdater.forceUpdate.value?.versionCode, 20);
    });

    test('达到最低版本后清掉强制更新状态', () async {
      const forced = AppUpdate(
        versionCode: 20,
        versionName: '1.0.20',
        apkUrl: '/app/download/piggy-pal-1.0.20-20.apk',
        size: 21500000,
        sha256: 'abc',
        changelog: '',
        force: true,
        minVersionCode: 19,
      );
      await AppUpdater.onServerUpdate(forced);
      expect(AppUpdater.forceUpdate.value, isNotNull);

      // 服务端把 min 调回 0（或本地已经是新版）：状态要跟着清掉
      await AppUpdater.onServerUpdate(_newVersion);
      expect(AppUpdater.forceUpdate.value, isNull);
    });
  });

  group('新版本通知（心跳下发）', () {
    final toastCalls = <String>[];

    setUp(() {
      PackageInfo.setMockInitialValues(
        appName: 'PiggyPal',
        packageName: 'com.piggypal.piggy_pal',
        version: '1.0.2',
        buildNumber: '3',
        buildSignature: '',
      );
      SharedPreferences.setMockInitialValues({});
      AppUpdater.availableUpdate.debugReset();
      toastCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('piggy_pal/ui'), (
            call,
          ) async {
            if (call.method == 'showToast') {
              final args = (call.arguments as Map).cast<String, dynamic>();
              toastCalls.add(args['text'] as String);
            }
            return true;
          });
    });

    tearDown(() {
      AppUpdater.availableUpdate.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('piggy_pal/ui'), null);
    });

    test('收到通知：亮红点 + Toast，同一版本只提示一次', () async {
      // buildNumber=3，服务端 3 属于同一版，这里用一个更新的版本
      const newer = AppUpdate(
        versionCode: 6,
        versionName: '1.0.5',
        apkUrl: '/app/download/piggy-pal-1.0.5-6.apk',
        size: 21308842,
        sha256: 'abc',
        changelog: '设备标识',
        force: false,
      );

      await AppUpdater.onServerUpdate(newer);
      expect(AppUpdater.hasUpdate, isTrue);
      expect(AppUpdater.hasBadge, isTrue);
      expect(toastCalls, hasLength(1));
      expect(toastCalls.single, contains('v1.0.5'));
      expect(toastCalls.single, contains('关于'));

      // 模拟重启：内存状态清空，但本地已经提示过这一版
      AppUpdater.availableUpdate.debugReset();
      await AppUpdater.onServerUpdate(newer);
      expect(AppUpdater.hasBadge, isTrue);
      expect(toastCalls, hasLength(1), reason: '同一个版本只 Toast 一次');
    });

    test('已经装上新版本（或更新）时不下发提示', () async {
      // 服务端版本 3 = 本地 buildNumber 3
      await AppUpdater.onServerUpdate(_newVersion);
      expect(AppUpdater.hasUpdate, isFalse);
      expect(AppUpdater.hasBadge, isFalse);
      expect(toastCalls, isEmpty);
    });

    testWidgets('一级入口（三横线）和抽屉里的红点一起亮、一起灭', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                UpdateBadge(key: Key('menu'), child: Text('菜单')),
                UpdateBadge(key: Key('about'), child: Text('关于')),
              ],
            ),
          ),
        ),
      );
      expect(_redDotCount(tester), 0);

      // 服务端/静默检查发现新版本：内外两个红点同时亮
      AppUpdater.availableUpdate.value = _newVersion;
      await tester.pump();
      expect(_redDotCount(tester), 2);

      // 家长点进「关于」看过一次：两个红点一起消失
      await AppUpdater.markSeen();
      await tester.pump();
      expect(_redDotCount(tester), 0);
      expect(AppUpdater.hasUpdate, isTrue);
    });

    test('看过一次后红点不再亮，重开 App 也不会再亮', () async {
      const newer = AppUpdate(
        versionCode: 6,
        versionName: '1.0.5',
        apkUrl: '/app/download/piggy-pal-1.0.5-6.apk',
        size: 1,
        sha256: '',
        changelog: '',
        force: false,
      );
      await AppUpdater.onServerUpdate(newer);
      expect(AppUpdater.hasBadge, isTrue);

      await AppUpdater.markSeen();
      expect(AppUpdater.hasBadge, isFalse, reason: '看过一次内外红点都消掉');
      expect(AppUpdater.hasUpdate, isTrue, reason: '版本信息要保留给「关于」页展示');

      // 重启：恢复已读状态，红点保持熄灭
      AppUpdater.availableUpdate.debugReset();
      await AppUpdater.restoreSeen();
      AppUpdater.availableUpdate.value = newer;
      expect(AppUpdater.hasBadge, isFalse);
    });
  });
}

/// 数一数页面里有几个「红底圆形」——就是 [UpdateBadge] 的红点。
int _redDotCount(WidgetTester tester) {
  return tester.widgetList<Container>(find.byType(Container)).where((c) {
    final d = c.decoration;
    return d is BoxDecoration &&
        d.shape == BoxShape.circle &&
        d.color == const Color(0xFFEF4444);
  }).length;
}
