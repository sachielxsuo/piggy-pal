import 'package:flutter/material.dart';

import '../services/app_updater.dart';

/// 「有新版本」红点：静默检查 / 心跳发现更新时，在入口右上角点一个小红点。
///
/// 只做提示，不自动弹窗；家长自己点进「关于 → 检查更新」再走更新流程。
/// 家长看过一次后（[AppUpdater.markSeen]）内外红点一起熄灭。
class UpdateBadge extends StatelessWidget {
  /// 红点挂在谁身上；为空时只有红点。
  final Widget? child;

  /// 红点直径，默认 9。
  final double size;

  const UpdateBadge({super.key, this.child, this.size = 9});

  @override
  Widget build(BuildContext context) {
    // 监听「是否还有没看过的更新」而不是版本信息本身：
    // 家长进过一次「关于」，内外红点就一起消失，不用等下次心跳。
    return ValueListenableBuilder<bool>(
      valueListenable: AppUpdater.availableUpdate.badge,
      builder: (_, hasBadge, _) {
        if (!hasBadge) return child ?? const SizedBox.shrink();
        final dot = Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFFEF4444),
            shape: BoxShape.circle,
            // 白描边让红点在任意底色上都清楚
            border: Border.all(color: Colors.white, width: 1.5),
          ),
        );
        if (child == null) return dot;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            child!,
            Positioned(top: -2, right: -2, child: dot),
          ],
        );
      },
    );
  }
}
