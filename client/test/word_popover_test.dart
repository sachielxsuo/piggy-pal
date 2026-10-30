import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/word_entry.dart';
import 'package:piggy_pal/widgets/word_popover.dart';
import 'package:piggy_pal/widgets/word_sheet.dart';

const _entry = WordEntry(
  word: 'dinosaurs',
  lemma: 'dinosaur',
  phonetic: '/ˈdaɪnəsɔːr/',
  senses: ['恐龙'],
  level: 'kid',
  found: true,
  audioB64: 'AAAA',
  audioSlowB64: 'BBBB',
  audioSource: 'human',
);

/// 弹出一个 popover，返回卡片矩形（调用方先 pumpAndSettle）。
Future<Rect> _open(
  WidgetTester tester, {
  required Rect anchor,
}) async {
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  showWordPopover(
    context: ctx,
    anchor: anchor,
    builder: (_) => WordSheet(
      word: 'dinosaurs',
      childId: 'anan',
      roleId: 'peppa',
      initialEntry: _entry,
      onPlay: (_) async {},
    ),
  );
  await tester.pumpAndSettle();
  return tester.getRect(find.byType(WordSheet));
}

void main() {
  testWidgets('卡片贴在单词上方，水平居中对齐单词', (tester) async {
    const anchor = Rect.fromLTWH(300, 460, 70, 22);
    final card = await _open(tester, anchor: anchor);

    expect(card.bottom, lessThanOrEqualTo(anchor.top));
    expect(anchor.top - card.bottom, lessThan(20)); // 只有一个箭头 + 小间距
    expect((card.center.dx - anchor.center.dx).abs(), lessThan(2));
    expect(card.width, lessThanOrEqualTo(360));

    // 不该再出现底部弹层
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('dinosaur'), findsOneWidget);
  });

  testWidgets('单词太靠上时落到下方，仍然水平居中', (tester) async {
    const anchor = Rect.fromLTWH(300, 30, 70, 22);
    final card = await _open(tester, anchor: anchor);

    expect(card.top, greaterThanOrEqualTo(anchor.bottom));
    expect(card.top - anchor.bottom, lessThan(20));
    expect((card.center.dx - anchor.center.dx).abs(), lessThan(2));
  });

  testWidgets('靠边时卡片不超出屏幕', (tester) async {
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    const anchor = Rect.fromLTWH(4, 460, 24, 22);
    final card = await _open(tester, anchor: anchor);

    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(screen.width));
  });

  testWidgets('点空白处关闭', (tester) async {
    const anchor = Rect.fromLTWH(300, 460, 70, 22);
    await _open(tester, anchor: anchor);

    await tester.tapAt(const Offset(6, 6));
    await tester.pumpAndSettle();
    expect(find.byType(WordSheet), findsNothing);
  });
}
