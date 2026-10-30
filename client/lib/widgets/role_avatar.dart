import 'package:flutter/material.dart';

import '../models/role.dart';

/// 角色形象。
///
/// 图片按约定从 `assets/<role_id>.png` 读（见 [Role.image]），但这些图片的
/// 版权归各自权利人，**不进仓库**，需要自己在本地放一份，见
/// `docs/配置引导.md` 的「角色形象」一节。
///
/// 没放图片不会崩：退化成带角色名首字的纯色圆头像，
/// 保证刚 clone 下来的人直接 `flutter run` 就能看到界面。
class RoleAvatar extends StatelessWidget {
  final Role role;
  final double height;

  const RoleAvatar({super.key, required this.role, required this.height});

  /// 按 role_id 挑一个稳定的颜色，同一个角色每次都一样。
  static const _palette = [
    Color(0xFFEC4899),
    Color(0xFF3B82F6),
    Color(0xFF10B981),
    Color(0xFFF59E0B),
    Color(0xFF8B5CF6),
    Color(0xFFEF4444),
  ];

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      role.image,
      height: height,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => _placeholder(),
    );
  }

  Widget _placeholder() {
    final color = _palette[role.id.codeUnits.fold<int>(0, (a, b) => a + b) %
        _palette.length];
    final initial = role.name.isEmpty ? '?' : role.name.substring(0, 1);
    return Container(
      height: height,
      width: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color, width: 4),
      ),
      child: Text(
        initial,
        style: TextStyle(
          fontSize: height * 0.4,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }
}
