import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/app_update.dart';
import 'package:piggy_pal/widgets/force_update_dialog.dart';

const _forced = AppUpdate(
  versionCode: 20,
  versionName: '1.0.20',
  apkUrl: '/app/download/piggy-pal-1.0.20-20.apk',
  size: 21500000,
  sha256: 'abc',
  changelog: '协议升级',
  force: true,
  minVersionCode: 19,
);

void main() {
  testWidgets('强制更新窗：关不掉，只能更新或退出', (tester) async {
    var exited = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ForceUpdateDialog(update: _forced, onExit: () async => exited++),
        ),
      ),
    );

    expect(find.text('需要更新一下才能继续'), findsOneWidget);
    expect(find.textContaining('v1.0.20'), findsOneWidget);
    expect(find.text('立即更新'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);

    // 不能有「取消 / 稍后」这类逃跑路线
    expect(find.text('取消'), findsNothing);
    expect(find.text('稍后'), findsNothing);

    // 返回键被 PopScope 挡住
    final popScope = tester.widget<PopScope>(find.byType(PopScope));
    expect(popScope.canPop, isFalse);

    // 退出的回调能触发
    await tester.tap(find.text('退出'));
    await tester.pump();
    expect(exited, 1);
  });
}
