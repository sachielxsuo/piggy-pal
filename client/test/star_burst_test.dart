import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggy_pal/widgets/star_burst.dart';

void main() {
  testWidgets('得星动效显示星星数量并在结束后回调', (tester) async {
    var done = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: StarBurst(stars: 3, onDone: () => done = true)),
      ),
    );

    expect(find.text('+3 颗星星'), findsOneWidget);
    expect(find.text('太棒啦！'), findsOneWidget);
    expect(done, isFalse);

    // 动画时长 1.6s，推进后应通知父组件移除自己
    await tester.pump(const Duration(milliseconds: 1700));
    expect(done, isTrue);
  });
}
