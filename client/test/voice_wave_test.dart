import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggy_pal/widgets/voice_wave.dart';

void main() {
  testWidgets('音量波形随声音变大而升高', (tester) async {
    final level = ValueNotifier<double>(0);
    addTearDown(level.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: VoiceWave(level: level, color: Colors.black),
          ),
        ),
      ),
    );

    expect(find.byType(AnimatedContainer), findsNWidgets(9));
    final quiet = tester.getSize(find.byType(AnimatedContainer).last).height;

    // 说大声一点，最后一根柱子应该被抬高
    level.value = 0.9;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 150));

    final loud = tester.getSize(find.byType(AnimatedContainer).last).height;
    expect(loud, greaterThan(quiet));
  });
}
