import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 贴住单词的词典卡片（popover）。
///
/// 默认放在单词**上方**，只有上方空间实在不够时才落到下方；卡片高度跟着可用
/// 空间走，内容超出就在卡片内部滚动，不会像底部弹层那样盖住整块聊天。
///
/// [anchor] 是被点单词在屏幕坐标系里的矩形（由 [TappableText] 量出来）。
Future<void> showWordPopover({
  required BuildContext context,
  required Rect anchor,
  required WidgetBuilder builder,
}) {
  final geometry = _PopoverGeometry.resolve(context, anchor);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭词典',
    // 只压一点点，聊天内容仍然看得见
    barrierColor: Colors.black.withValues(alpha: 0.08),
    transitionDuration: const Duration(milliseconds: 170),
    pageBuilder: (dialogContext, _, _) => _WordPopover(
      geometry: geometry,
      child: Builder(builder: builder),
    ),
    transitionBuilder: (dialogContext, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: AnimatedBuilder(
          animation: curved,
          // 从箭头方向「推」出来：在上方就从下面顶上来，在下方就从上面落下来
          builder: (_, inner) => Transform.translate(
            offset: Offset(
              0,
              (1 - curved.value) * 8 * (geometry.above ? 1 : -1),
            ),
            child: inner,
          ),
          child: child,
        ),
      );
    },
  );
}

/// 卡片位置、宽度、箭头位置、朝上还是朝下——布局和动画都要用，先算一次。
class _PopoverGeometry {
  static const double margin = 12;
  static const double gap = 10;
  static const double maxWidth = 360;

  final Rect anchor;
  final Size screen;
  final EdgeInsets insets;
  final double width;
  final double left;
  final double arrowX;
  final bool above;
  final double maxHeight;

  const _PopoverGeometry({
    required this.anchor,
    required this.screen,
    required this.insets,
    required this.width,
    required this.left,
    required this.arrowX,
    required this.above,
    required this.maxHeight,
  });

  factory _PopoverGeometry.resolve(BuildContext context, Rect anchor) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    final insets = EdgeInsets.fromLTRB(
      media.padding.left + margin,
      media.padding.top + margin,
      media.padding.right + margin,
      media.padding.bottom + margin,
    );
    final width = math.min(maxWidth, screen.width - margin * 2);
    final left = (anchor.center.dx - width / 2)
        .clamp(margin, math.max(margin, screen.width - width - margin))
        .toDouble();
    final arrowX = (anchor.center.dx - left).clamp(18.0, width - 18.0).toDouble();

    final spaceAbove = anchor.top - gap - insets.top;
    final spaceBelow = screen.height - insets.bottom - anchor.bottom - gap;
    // 优先上方；上方连半个屏幕都放不下、而下方更宽裕时才落到下方
    final above = spaceAbove >= 200 || spaceAbove >= spaceBelow;
    final space = above ? spaceAbove : spaceBelow;

    return _PopoverGeometry(
      anchor: anchor,
      screen: screen,
      insets: insets,
      width: width,
      left: left,
      arrowX: arrowX,
      above: above,
      // 极端小屏保底 160，宁可稍微盖住单词也要能看清释义
      maxHeight: math.max(space, 160),
    );
  }

  double topFor(double cardHeight) {
    var y = above ? anchor.top - gap - cardHeight : anchor.bottom + gap;
    final maxY = screen.height - insets.bottom - cardHeight;
    if (maxY >= insets.top) y = y.clamp(insets.top, maxY);
    return y;
  }
}

class _WordPopover extends StatelessWidget {
  final _PopoverGeometry geometry;
  final Widget child;

  const _WordPopover({required this.geometry, required this.child});

  @override
  Widget build(BuildContext context) {
    return CustomSingleChildLayout(
      delegate: _PopoverLayout(geometry),
      child: _buildCard(),
    );
  }

  /// 卡片在单词上方时，箭头挂在卡片下沿。
  Widget _buildCard() {
    final arrowBelow = geometry.above;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: geometry.arrowX - 7.5,
          top: arrowBelow ? null : -7,
          bottom: arrowBelow ? -7 : null,
          child: Transform.rotate(
            angle: math.pi / 4,
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(3),
                boxShadow: const [
                  BoxShadow(color: Color(0x141E40AF), blurRadius: 8),
                ],
              ),
            ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: const [
              BoxShadow(
                color: Color(0x241E40AF),
                blurRadius: 26,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Material(color: Colors.white, child: child),
        ),
      ],
    );
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  final _PopoverGeometry geometry;

  _PopoverLayout(this.geometry);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: geometry.width,
      minWidth: geometry.width,
      maxHeight: geometry.maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    return Offset(geometry.left, geometry.topFor(childSize.height));
  }

  @override
  bool shouldRelayout(covariant _PopoverLayout oldDelegate) =>
      oldDelegate.geometry != geometry;
}
