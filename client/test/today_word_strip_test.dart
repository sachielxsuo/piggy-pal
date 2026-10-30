import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/target_word.dart';
import 'package:piggy_pal/widgets/today_word_strip.dart';

void main() {
  testWidgets('词卡展示英文、中文和听过/说过/未出现三种状态', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayWordStrip(
            words: const [
              TargetWord(en: 'cat', zh: '猫', heard: true, said: true),
              TargetWord(en: 'dog', zh: '狗', heard: true),
              TargetWord(en: 'pig', zh: '猪', justSaid: true),
            ],
            onTap: (w) => tapped.add(w.en),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('cat'), findsOneWidget);
    expect(find.text('猫'), findsOneWidget);
    expect(find.text('✅'), findsOneWidget);
    expect(find.text('🔊'), findsOneWidget);
    expect(find.text('✨'), findsOneWidget);

    await tester.tap(find.text('dog'));
    expect(tapped, ['dog']);
  });

  testWidgets('没有目标词时不占位置', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayWordStrip(words: const [], onTap: (_) {}),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ListView), findsNothing);
  });
}
