import 'package:flutter/material.dart';

/// 等待 AI 回复时的「正在想」气泡：三个小点依次跳动。
class TypingBubble extends StatefulWidget {
  final String label;

  const TypingBubble({super.key, required this.label});

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22),
            topRight: Radius.circular(22),
            bottomLeft: Radius.circular(8),
            bottomRight: Radius.circular(22),
          ),
          boxShadow: const [
            BoxShadow(color: Color(0x141E40AF), blurRadius: 12),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.label,
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
            ),
            const SizedBox(width: 8),
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [for (var i = 0; i < 3; i++) _dot(i)],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(int index) {
    // 每个点错开 0.18 个周期，形成「依次跳动」
    final phase = (_controller.value - index * 0.18) % 1.0;
    final wave = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
    final scale = 0.7 + wave * 0.6;
    final opacity = 0.35 + wave * 0.65;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.5),
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: const Color(0xFF1D4ED8).withValues(alpha: opacity),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
