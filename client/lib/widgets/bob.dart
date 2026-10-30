import 'package:flutter/material.dart';

/// 让角色轻轻上下浮动，像在呼吸/等宝宝说话，增加「活着」的感觉。
class Bob extends StatefulWidget {
  final Widget child;
  final double distance;
  final Duration duration;

  const Bob({
    super.key,
    required this.child,
    this.distance = 6,
    this.duration = const Duration(milliseconds: 2200),
  });

  @override
  State<Bob> createState() => _BobState();
}

class _BobState extends State<Bob> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // easeInOut 让上下浮动更像自然呼吸
        final t = Curves.easeInOut.transform(_controller.value);
        return Transform.translate(
          offset: Offset(0, -widget.distance * t),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
