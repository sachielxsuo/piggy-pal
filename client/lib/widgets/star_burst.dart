import 'dart:math';

import 'package:flutter/material.dart';

/// 获得星星时的夸张动效：中心弹出大星星 + 星星四散 + 金色光环。
///
/// 只做展示，`IgnorePointer` 保证不挡宝宝继续点屏幕；
/// 动画结束后通过 [onDone] 通知父组件移除自己。
class StarBurst extends StatefulWidget {
  final int stars;

  /// 自定义奖励文案；为空时显示「+N 颗星星」。
  final String? badgeText;

  /// 自定义副标题；为空时显示「太棒啦！」。
  final String? subtitle;

  final VoidCallback? onDone;

  const StarBurst({
    super.key,
    required this.stars,
    this.badgeText,
    this.subtitle,
    this.onDone,
  });

  @override
  State<StarBurst> createState() => _StarBurstState();
}

class _StarBurstState extends State<StarBurst>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 1600);
  static const List<String> _emojis = ['⭐', '🌟', '✨', '💫'];

  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    // 固定种子：同一次奖励的粒子布局稳定，不会每帧乱跳
    final rnd = Random(widget.stars * 7919 + 17);
    _particles = List.generate(20, (i) {
      final base = (i / 20) * 2 * pi;
      final angle = base + (rnd.nextDouble() - 0.5) * 0.45;
      return _Particle(
        angle: angle,
        distanceRatio: 0.55 + rnd.nextDouble() * 0.55,
        size: 15 + rnd.nextDouble() * 17,
        delay: rnd.nextDouble() * 0.16,
        spin: (rnd.nextDouble() - 0.5) * 3.2,
        emoji: _emojis[i % _emojis.length],
      );
    });

    _controller = AnimationController(vsync: this, duration: _duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDone?.call();
      })
      ..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final center = Offset(
            constraints.maxWidth / 2,
            constraints.maxHeight * 0.34,
          );
          final maxDistance = min(constraints.maxWidth * 0.55, 240.0);

          return AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = _controller.value;
              final fade = t < 0.74
                  ? 1.0
                  : (1 - (t - 0.74) / 0.26).clamp(0.0, 1.0);
              return Stack(
                children: [
                  // 光环：两圈错开的金色扩散圆环
                  _ring(center, t, 0.0),
                  _ring(center, t, 0.14),
                  // 四散的星星
                  for (final p in _particles)
                    _particle(p, center, maxDistance, t),
                  // 中心大星星 + 数量
                  _centerBadge(center, t, fade),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _ring(Offset center, double t, double delay) {
    final local = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
    if (local <= 0) return const SizedBox.shrink();
    final radius = 62 + 150 * Curves.easeOutCubic.transform(local);
    final opacity = (1 - local) * 0.5;
    return Positioned(
      left: center.dx - radius,
      top: center.dy - radius,
      child: Container(
        width: radius * 2,
        height: radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: const Color(0xFFFBBF24).withValues(alpha: opacity),
            width: 3,
          ),
        ),
      ),
    );
  }

  Widget _particle(_Particle p, Offset center, double maxDistance, double t) {
    final local = ((t - p.delay) / (1 - p.delay)).clamp(0.0, 1.0);
    if (local <= 0) return const SizedBox.shrink();
    final travel = Curves.easeOutCubic.transform(local);
    final dx = cos(p.angle) * maxDistance * p.distanceRatio * travel;
    final dy =
        sin(p.angle) * maxDistance * p.distanceRatio * travel - 26 * local;
    // 快速放大再缩小 + 淡出
    final pop = Curves.easeOutBack.transform(min(1.0, local * 3.2));
    final scale = (0.5 + 0.9 * pop) * (1 - 0.35 * local);
    final opacity = local < 0.12
        ? local / 0.12
        : (1 - (local - 0.12) / 0.88).clamp(0.0, 1.0);

    return Positioned(
      left: center.dx + dx - p.size / 2,
      top: center.dy + dy - p.size / 2,
      child: Transform.rotate(
        angle: p.spin * local,
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Text(p.emoji, style: TextStyle(fontSize: p.size)),
          ),
        ),
      ),
    );
  }

  Widget _centerBadge(Offset center, double t, double fade) {
    final appear = (t / 0.5).clamp(0.0, 1.0);
    final scale = Curves.elasticOut.transform(appear);
    final rise = 26 * Curves.easeOutCubic.transform(t);

    return Positioned(
      left: 0,
      right: 0,
      top: center.dy - 96 - rise,
      child: Opacity(
        opacity: fade,
        child: Center(
          child: Transform.scale(
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 132,
                  height: 132,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [Color(0xFFFFF7DB), Color(0xFFFBBF24)],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x66F59E0B),
                        blurRadius: 40,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.star_rounded,
                    size: 96,
                    color: Color(0xFFFFFFFF),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: const [
                      BoxShadow(color: Color(0x55F59E0B), blurRadius: 18),
                    ],
                  ),
                  child: Text(
                    widget.badgeText ?? '+${widget.stars} 颗星星',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.subtitle ?? '太棒啦！',
                  style: const TextStyle(
                    color: Color(0xFFB45309),
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Particle {
  final double angle;
  final double distanceRatio;
  final double size;
  final double delay;
  final double spin;
  final String emoji;

  const _Particle({
    required this.angle,
    required this.distanceRatio,
    required this.size,
    required this.delay,
    required this.spin,
    required this.emoji,
  });
}
