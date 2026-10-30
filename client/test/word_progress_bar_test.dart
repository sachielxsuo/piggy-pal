import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/widgets/stats_widgets.dart';

void main() {
  testWidgets('进度条显示标签、分数和比例', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WordProgressBar(
            label: '听到',
            value: 3,
            total: 5,
            color: Color(0xFF3B82F6),
          ),
        ),
      ),
    );

    expect(find.text('听到'), findsOneWidget);
    expect(find.text('3/5'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.6, 0.0001));
  });

  testWidgets('超出计划数时按满分显示，总数为 0 时不崩', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              WordProgressBar(label: '说出', value: 7, total: 5),
              WordProgressBar(label: '空计划', value: 0, total: 0),
            ],
          ),
        ),
      ),
    );

    expect(find.text('5/5'), findsOneWidget);
    expect(find.text('0/0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
