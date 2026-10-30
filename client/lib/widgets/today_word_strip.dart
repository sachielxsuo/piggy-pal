import 'package:flutter/material.dart';

import '../models/target_word.dart';

/// 对话页顶部的「今日词卡」：5 个目标词横向排列。
/// 点一下听发音；说过 / 听过用不同的底色和角标区分，
/// 让不认识字的 4-6 岁孩子也能靠颜色和图标看懂进度。
class TodayWordStrip extends StatelessWidget {
  final List<TargetWord> words;
  final ValueChanged<TargetWord> onTap;

  const TodayWordStrip({
    super.key,
    required this.words,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (words.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 70,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: words.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => _WordChip(word: words[i], onTap: onTap),
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  final TargetWord word;
  final ValueChanged<TargetWord> onTap;

  const _WordChip({required this.word, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color border;
    final String badge;
    if (word.said) {
      bg = const Color(0xFFDCFCE7);
      border = const Color(0xFF86EFAC);
      badge = '✅';
    } else if (word.heard) {
      bg = const Color(0xFFEFF6FF);
      border = const Color(0xFFBFDBFE);
      badge = '🔊';
    } else {
      bg = Colors.white.withValues(alpha: 0.88);
      border = const Color(0xFFE2E8F0);
      badge = '✨';
    }

    return Semantics(
      button: true,
      label: '${word.en} ${word.zh}',
      child: InkWell(
        onTap: () => onTap(word),
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: 96,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: word.justSaid ? const Color(0xFF22C55E) : border,
              width: word.justSaid ? 2 : 1,
            ),
            boxShadow: const [
              BoxShadow(color: Color(0x121E40AF), blurRadius: 8),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      word.en,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF1E3A8A),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(badge, style: const TextStyle(fontSize: 10)),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                word.zh,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
