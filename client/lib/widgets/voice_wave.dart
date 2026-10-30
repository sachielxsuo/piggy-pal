import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 按住说话时的音量波形：一排小柱子跟着宝宝的声音跳动。
class VoiceWave extends StatefulWidget {
  /// 0~1 的实时音量。
  final ValueListenable<double> level;
  final Color color;
  final int barCount;
  final double maxHeight;

  const VoiceWave({
    super.key,
    required this.level,
    this.color = Colors.white,
    this.barCount = 9,
    this.maxHeight = 26,
  });

  @override
  State<VoiceWave> createState() => _VoiceWaveState();
}

class _VoiceWaveState extends State<VoiceWave> {
  late final List<double> _bars = List<double>.filled(widget.barCount, 0.12);
  double _smoothed = 0;

  @override
  void initState() {
    super.initState();
    widget.level.addListener(_onLevel);
  }

  @override
  void didUpdateWidget(covariant VoiceWave oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.level != widget.level) {
      oldWidget.level.removeListener(_onLevel);
      widget.level.addListener(_onLevel);
    }
  }

  @override
  void dispose() {
    widget.level.removeListener(_onLevel);
    super.dispose();
  }

  void _onLevel() {
    // 稍微平滑一下，柱子不会一抖一抖
    _smoothed = _smoothed * 0.35 + widget.level.value * 0.65;
    setState(() {
      for (var i = 0; i < _bars.length - 1; i++) {
        _bars[i] = _bars[i + 1];
      }
      _bars[_bars.length - 1] = _smoothed;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 相邻柱子高低错开一点，看起来更像真实的声波
    const pattern = [0.55, 0.8, 1.0, 0.72, 0.9, 0.65, 0.95, 0.75, 0.6];
    return SizedBox(
      height: widget.maxHeight,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (var i = 0; i < _bars.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 110),
                curve: Curves.easeOut,
                width: 3.5,
                height:
                    (4 +
                            _bars[i] *
                                pattern[i % pattern.length] *
                                (widget.maxHeight - 4))
                        .clamp(4.0, widget.maxHeight),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
