import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/widgets/tappable_text.dart';

void main() {
  testWidgets('点英文单词会回调单词和它在屏幕上的位置', (tester) async {
    final hits = <String>[];
    final rects = <Rect>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // 收窄宽度，强制英文行换行，才能验证多行里单词的纵向位置
            child: SizedBox(
              width: 110,
              child: TappableText(
                text: 'Look, a dinosaur!\n看，一只恐龙！',
                style: const TextStyle(fontSize: 16),
                onWordTap: (word, rect) {
                  hits.add(word);
                  rects.add(rect);
                },
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapOnText(find.textRange.ofSubstring('dinosaur'));
    expect(hits, ['dinosaur']);

    // 位置要能定位到单词本身：宽度合理，且落在文本区域内
    final textRect = tester.getRect(find.byType(TappableText));
    final wordRect = rects.single;
    expect(wordRect.width, greaterThan(20));
    expect(wordRect.height, greaterThan(10));
    expect(textRect.inflate(1).contains(wordRect.center), isTrue);

    await tester.tapOnText(find.textRange.ofSubstring('Look'));
    expect(hits, ['dinosaur', 'Look']);
    // Look 在第一行，dinosaur 在第二行
    expect(rects[1].top, lessThan(rects[0].top));

    expect(find.textContaining('看，一只恐龙！'), findsOneWidget);
    expect(find.textContaining('dinosaur'), findsOneWidget);
  });

  testWidgets('没有回调时退化成普通文本', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TappableText(text: 'Hello there', style: TextStyle(fontSize: 16)),
        ),
      ),
    );
    expect(find.text('Hello there'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
