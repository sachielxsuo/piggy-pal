import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/child.dart';
import '../services/api_client.dart';
import '../services/logger.dart';
import 'child_form_page.dart';

class ChildSelectPage extends StatefulWidget {
  const ChildSelectPage({super.key});

  @override
  State<ChildSelectPage> createState() => _ChildSelectPageState();
}

class _ChildSelectPageState extends State<ChildSelectPage> {
  final ApiClient _api = ApiClient();
  final List<Child> _children = [];
  String? _currentId;
  bool _loading = true;
  bool _loadFailed = false;

  /// 开发者模式开启时才展示 family_id=dev 的测试宝宝。
  bool _devMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      _currentId = prefs.getString('child_id');
      final devMode = prefs.getBool('dev_mode') ?? false;
      AppLog.i(
        'child',
        '本地缓存读取正常 current=${_currentId ?? '-'} devMode=$devMode',
      );
      final list = await _api.fetchChildren();
      // 开发者模式关闭时隐藏测试宝宝（family_id=dev / dev_ 前缀）
      final visible = devMode
          ? list
          : list.where((c) => !c.isDevChild).toList();
      AppLog.i(
        'child',
        '宝宝列表加载成功 count=${visible.length} total=${list.length}',
      );
      if (!mounted) return;
      setState(() {
        _children
          ..clear()
          ..addAll(visible);
        _devMode = devMode;
        _loading = false;
        _loadFailed = false;
      });
    } catch (e) {
      // 后端不可达 / 本地缓存异常：保留空列表，但明确提示，不再无限转圈
      AppLog.w('child', '加载宝宝列表失败: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  Future<void> _select(Child c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('child_id', c.childId);
    await prefs.setString('child_name', c.name);
    await prefs.setString('child_avatar', c.avatar);
    if (mounted) Navigator.of(context).pop(c.childId);
  }

  Future<void> _add() async {
    final child = await Navigator.of(context)
        .push<Child>(MaterialPageRoute(builder: (_) => const ChildFormPage()));
    if (child == null) return;
    // 表单里已经保存到服务端，这里只需要切换过去
    await _select(child);
  }

  Future<void> _edit(Child c) async {
    final updated = await Navigator.of(
      context,
    ).push<Child>(MaterialPageRoute(builder: (_) => ChildFormPage(initial: c)));
    if (updated == null) return;
    await _load();
    // 改的是当前宝宝：同步首页缓存的名字 / 头像
    if (_currentId == updated.childId) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('child_name', updated.name);
      await prefs.setString('child_avatar', updated.avatar);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('选宝宝'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
                children: [
                  if (_loadFailed) _buildOfflineBanner(),
                  if (_devMode) _buildDevBanner(),
                  if (_children.isEmpty) _buildEmpty(),
                  ..._children.map(_buildChildTile),
                  const SizedBox(height: 6),
                  _buildAddTile(),
                ],
              ),
            ),
    );
  }

  Widget _buildOfflineBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, size: 18, color: Color(0xFFB45309)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '暂时连不上服务器，宝宝列表可能不全',
              style: TextStyle(color: Color(0xFF92400E), fontSize: 12),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _buildDevBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE9FE),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        children: [
          Icon(Icons.bug_report_outlined, size: 18, color: Color(0xFF6D28D9)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '开发者模式：显示测试宝宝（关闭后自动隐藏）',
              style: TextStyle(color: Color(0xFF5B21B6), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 26),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: const Column(
        children: [
          Text('👶', style: TextStyle(fontSize: 46)),
          SizedBox(height: 10),
          Text(
            '还没有宝宝档案',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          SizedBox(height: 4),
          Text(
            '点下面的「添加宝宝」，填个名字就能开始',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildChildTile(Child c) {
    final selected = _currentId == c.childId;
    final meta = <String>[
      if (c.enName.isNotEmpty) c.enName,
      if (c.age > 0) '${c.age} 岁',
      if (c.gender.isNotEmpty) c.gender,
      if (c.preferences.isNotEmpty) '喜欢${c.preferences}',
    ].join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: selected ? const Color(0xFF93C5FD) : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        leading: CircleAvatar(
          radius: 24,
          backgroundColor: const Color(0xFFDBEAFE),
          child: Text(
            c.avatar.isEmpty ? '👶' : c.avatar,
            style: const TextStyle(fontSize: 23),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            if (c.isDevChild) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFFEDE9FE),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  '测试',
                  style: TextStyle(fontSize: 10, color: Color(0xFF6D28D9)),
                ),
              ),
            ],
            if (selected) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.check_circle,
                size: 16,
                color: Color(0xFF10B981),
              ),
            ],
          ],
        ),
        subtitle: Text(
          meta.isEmpty ? '点一下开始' : meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
        ),
        trailing: IconButton(
          tooltip: '编辑',
          icon: const Icon(Icons.edit_outlined, size: 20),
          color: const Color(0xFF64748B),
          onPressed: () => _edit(c),
        ),
        onTap: () => _select(c),
      ),
    );
  }

  Widget _buildAddTile() {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _add,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  color: Color(0xFF1D4ED8),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add, color: Colors.white),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '添加宝宝',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '名字、年龄、头像和喜好都可以在这里填',
                      style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
            ],
          ),
        ),
      ),
    );
  }
}
