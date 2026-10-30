import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/models/word_entry.dart';
import 'package:piggy_pal/widgets/word_sheet.dart';

const _entry = WordEntry(
  word: 'dinosaurs',
  lemma: 'dinosaur',
  phonetic: '/ˈdaɪnəsɔːr/',
  senses: ['恐龙'],
  level: 'kid',
  found: true,
  example: WordSentence(en: 'The dinosaur is big.', zh: '恐龙很大。'),
  context: WordSentence(en: 'Look, a dinosaur!', zh: '看，一只恐龙！'),
  audioB64: 'AAAA',
  audioSlowB64: 'BBBB',
  audioSource: 'human',
  audioCredit: 'Dvortygirl · CC BY-SA 3.0 · Wikimedia Commons',
);

void main() {
  testWidgets('词典卡片展示音标、释义、原句、例句和两种发音', (tester) async {
    final played = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordSheet(
            word: 'dinosaurs',
            childId: 'anan',
            roleId: 'peppa',
            initialEntry: _entry,
            onPlay: (b64) async => played.add(b64),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('dinosaur'), findsOneWidget);
    expect(find.text('/ˈdaɪnəsɔːr/'), findsOneWidget);
    expect(find.text('恐龙'), findsOneWidget);
    expect(find.text('在这句话里'), findsOneWidget);
    expect(find.text('Look, a dinosaur!'), findsOneWidget);
    expect(find.text('例句'), findsOneWidget);
    expect(find.text('The dinosaur is big.'), findsOneWidget);
    expect(find.text('真人发音'), findsOneWidget);

    // 打开时自动读一遍正常语速
    expect(played, ['AAAA']);

    await tester.tap(find.text('慢读'));
    await tester.pump();
    expect(played.last, 'BBBB');
  });

  testWidgets('查不到词时给出友好提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WordSheet(
            word: 'zzzzzz',
            childId: 'anan',
            roleId: 'peppa',
            initialEntry: const WordEntry(
              word: 'zzzzzz',
              lemma: 'zzzzzz',
              phonetic: '',
              senses: [],
              level: '',
              found: false,
            ),
            onPlay: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('还没学会'), findsOneWidget);
    expect(find.text('正常'), findsNothing);
  });
}
