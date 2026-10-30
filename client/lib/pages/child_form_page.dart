import 'package:flutter/material.dart';

import '../models/child.dart';
import '../services/api_client.dart';

/// 添加 / 编辑宝宝档案：中文名、英文名、年龄、性别、头像、喜好。
///
/// 保存成功后 pop 出最新的 [Child]，由调用方决定是否切换为当前宝宝。
class ChildFormPage extends StatefulWidget {
  final Child? initial;

  const ChildFormPage({super.key, this.initial});

  @override
  State<ChildFormPage> createState() => _ChildFormPageState();
}

class _ChildFormPageState extends State<ChildFormPage> {
  static const List<String> _avatarOptions = [
    '🐷',
    '🐰',
    '🐻',
    '🦖',
    '🐱',
    '🐶',
    '🦊',
    '🐼',
    '🐨',
    '🦁',
    '🐯',
    '🐸',
  ];

  static const List<String> _likeOptions = [
    '恐龙',
    '儿歌',
    '小动物',
    '汽车',
    '公主',
    '积木',
    '画画',
    '绘本',
    '音乐',
    '球类',
  ];

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final ApiClient _api = ApiClient();

  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _enCtrl = TextEditingController();
  final TextEditingController _otherCtrl = TextEditingController();

  final Set<String> _likes = {};
  int _age = 4;
  String _gender = '';
  String _avatar = _avatarOptions.first;
  bool _saving = false;

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final c = widget.initial;
    if (c != null) {
      _nameCtrl.text = c.name;
      _enCtrl.text = c.enName;
      _age = c.age.clamp(1, 12);
      _gender = c.gender;
      _avatar = c.avatar.isEmpty ? _avatarOptions.first : c.avatar;
      _restoreLikes(c.preferences);
    }
    // 输入时实时更新顶部预览卡
    _nameCtrl.addListener(_onTextChanged);
    _enCtrl.addListener(_onTextChanged);
    _otherCtrl.addListener(_onTextChanged);
  }

  /// 把服务端存的「恐龙、儿歌」拆成已选 chip + 其他爱好输入框。
  void _restoreLikes(String raw) {
    final all = raw
        .split(RegExp(r'[、,，]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet();
    _likes
      ..clear()
      ..addAll(all.where(_likeOptions.contains));
    _otherCtrl.text = all.where((e) => !_likeOptions.contains(e)).join('、');
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onTextChanged);
    _enCtrl.removeListener(_onTextChanged);
    _otherCtrl.removeListener(_onTextChanged);
    _nameCtrl.dispose();
    _enCtrl.dispose();
    _otherCtrl.dispose();
    super.dispose();
  }

  String get _previewName =>
      _nameCtrl.text.trim().isEmpty ? '宝宝名字' : _nameCtrl.text.trim();

  String get _previewEn =>
      _enCtrl.text.trim().isEmpty ? 'English name' : _enCtrl.text.trim();

  String get _preferencesText {
    final custom = _otherCtrl.text.trim();
    final list = [..._likes, if (custom.isNotEmpty) custom];
    return list.join('、');
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_saving) return;
    final child = Child(
      childId: widget.initial?.childId ??
          'child_${DateTime.now().millisecondsSinceEpoch}',
      familyId: widget.initial?.familyId ?? 'default',
      name: _nameCtrl.text.trim(),
      enName: _enCtrl.text.trim(),
      age: _age,
      gender: _gender,
      preferences: _preferencesText,
      avatar: _avatar,
    );
    setState(() => _saving = true);
    try {
      await _api.upsertChild(child);
      if (!mounted) return;
      Navigator.of(context).pop(child);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，请检查网络后重试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF4F9FF),
        title: Text(_editing ? '编辑宝宝' : '添加宝宝'),
      ),
      body: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
          children: [
            _buildPreview(),
            const SizedBox(height: 16),
            _card(
              title: '基本信息',
              hint: '英文名会用在聊天里，玩伴会这样叫宝宝',
              child: Column(
                children: [
                  TextFormField(
                    controller: _nameCtrl,
                    maxLength: 12,
                    textInputAction: TextInputAction.next,
                    decoration: _input(
                      label: '中文名',
                      hint: '比如：安安',
                      icon: Icons.badge_outlined,
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return '请填写中文名';
                      if (s.length > 12) return '名字太长啦，12 个字以内';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _enCtrl,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    decoration: _input(
                      label: '英文名',
                      hint: '比如：Anan',
                      icon: Icons.translate,
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return '请填写英文名';
                      if (s.length > 20) return '英文名太长啦';
                      if (!RegExp(r"^[A-Za-z][A-Za-z .'-]*$").hasMatch(s)) {
                        return '英文名只能填英文字母哦';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text(
                        '年龄',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.5,
                        ),
                      ),
                      const Spacer(),
                      _stepBtn(
                        icon: Icons.remove,
                        enabled: _age > 1,
                        onTap: () => setState(() => _age--),
                      ),
                      SizedBox(
                        width: 52,
                        child: Center(
                          child: Text(
                            '$_age',
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1D4ED8),
                            ),
                          ),
                        ),
                      ),
                      _stepBtn(
                        icon: Icons.add,
                        enabled: _age < 12,
                        onTap: () => setState(() => _age++),
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        '岁',
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _card(
              title: '性别',
              hint: '只是让称呼更自然，不选也可以',
              child: Wrap(
                spacing: 10,
                children: [
                  for (final g in ['男孩', '女孩', '先不填'])
                    ChoiceChip(
                      label: Text(g),
                      selected: _gender == _genderValue(g),
                      onSelected: (_) =>
                          setState(() => _gender = _genderValue(g)),
                    ),
                ],
              ),
            ),
            _card(
              title: '选个头像',
              hint: '会显示在宝宝列表和首页',
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final emoji in _avatarOptions) _avatarDot(emoji),
                ],
              ),
            ),
            _card(
              title: '宝宝喜欢什么',
              hint: '可多选。玩伴会在聊天里自然聊到这些兴趣',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final like in _likeOptions)
                        FilterChip(
                          label: Text(like),
                          selected: _likes.contains(like),
                          onSelected: (on) => setState(() {
                            if (on) {
                              _likes.add(like);
                            } else {
                              _likes.remove(like);
                            }
                          }),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _otherCtrl,
                    maxLength: 30,
                    textInputAction: TextInputAction.done,
                    decoration: _input(
                      label: '其他爱好（选填）',
                      hint: '比如：汪汪队、拼图',
                      icon: Icons.favorite_border,
                    ).copyWith(counterText: ''),
                    validator: (v) =>
                        (v ?? '').trim().length > 30 ? '最多 30 个字' : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            const Center(
              child: Text(
                '这些信息只保存在家庭自己的服务器上',
                style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(18, 8, 18, 12),
        child: SizedBox(
          height: 52,
          child: FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Colors.white,
                    ),
                  )
                : Text(
                    _editing ? '保存修改' : '保存，开始陪伴',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ===== 顶部实时预览 =====
  Widget _buildPreview() {
    final tags = <String>[
      '$_age 岁',
      if (_gender.isNotEmpty) _gender,
      if (_likes.isNotEmpty) _likes.take(2).join(' · '),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1D4ED8), Color(0xFF60A5FA)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [BoxShadow(color: Color(0x331D4ED8), blurRadius: 20)],
      ),
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 74,
            height: 74,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.92),
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Color(0x331E40AF), blurRadius: 10),
              ],
            ),
            child: Text(_avatar, style: const TextStyle(fontSize: 38)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _previewName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _previewEn,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in tags)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          t,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 复用组件 =====
  Widget _card({
    required String title,
    String? hint,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          if (hint != null) ...[
            const SizedBox(height: 3),
            Text(hint,
                style:
                    const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  InputDecoration _input({
    required String label,
    required String hint,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 20),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF1D4ED8), width: 1.4),
      ),
    );
  }

  Widget _stepBtn({
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton.filledTonal(
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFFEFF6FF),
        foregroundColor: const Color(0xFF1D4ED8),
        disabledBackgroundColor: const Color(0xFFF1F5F9),
        disabledForegroundColor: const Color(0xFFCBD5E1),
        minimumSize: const Size(38, 38),
      ),
    );
  }

  Widget _avatarDot(String emoji) {
    final selected = _avatar == emoji;
    return InkWell(
      onTap: () => setState(() => _avatar = emoji),
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFDBEAFE)
              : const Color(0xFFF8FAFC),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? const Color(0xFF1D4ED8) : Colors.transparent,
            width: 2,
          ),
          boxShadow: selected
              ? const [BoxShadow(color: Color(0x331D4ED8), blurRadius: 8)]
              : null,
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 24)),
      ),
    );
  }

  String _genderValue(String label) {
    switch (label) {
      case '男孩':
        return '男';
      case '女孩':
        return '女';
      default:
        return '';
    }
  }
}
