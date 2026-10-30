import 'dart:async';

import 'package:flutter/material.dart';

import '../models/bedtime_story.dart';
import '../models/role.dart';
import '../services/api_client.dart';
import '../services/audio_player.dart';
import '../services/logger.dart';

/// 睡前故事：每天一段简单英文 + 中文晚安，读起来约 1 分钟。
/// 默认用当前角色音色，支持「再慢一点」，不打断、不讲星星，形成睡前仪式。
class BedtimeStoryPage extends StatefulWidget {
  final String childId;
  final List<Role> roles;
  final String? initialRoleId;

  const BedtimeStoryPage({
    super.key,
    required this.childId,
    required this.roles,
    this.initialRoleId,
  });

  @override
  State<BedtimeStoryPage> createState() => _BedtimeStoryPageState();
}

class _BedtimeStoryPageState extends State<BedtimeStoryPage> {
  final ApiClient _api = ApiClient();
  final AudioPlayerService _player = AudioPlayerService();
  final Map<String, BedtimeStory> _cache = {};
  final Map<String, String> _slowAudio = {};

  late String _roleId;
  BedtimeStory? _story;
  bool _loading = true;
  bool _loadingSlow = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _roleId = widget.initialRoleId ?? widget.roles.first.id;
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_player.stop());
    _player.dispose();
    super.dispose();
  }

  Role? get _role {
    for (final r in widget.roles) {
      if (r.id == _roleId) return r;
    }
    return widget.roles.isEmpty ? null : widget.roles.first;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final cached = _cache[_roleId];
    if (cached != null) {
      setState(() {
        _story = cached;
        _loading = false;
      });
      _playAudio(cached.audioB64);
      return;
    }
    try {
      final story = await _api.fetchBedtimeStory(
        childId: widget.childId,
        roleId: _roleId,
      );
      AppLog.i(
        'story',
        '睡前故事就绪 role=$_roleId isNew=${story.isNew} '
            'textLen=${story.text.length} audio=${story.audioB64.length}',
      );
      if (!mounted) return;
      setState(() {
        _story = story;
        _cache[_roleId] = story;
        _loading = false;
      });
      _playAudio(story.audioB64);
    } catch (e) {
      AppLog.w('story', '睡前故事加载失败 role=$_roleId: $e');
      if (!mounted) return;
      setState(() {
        _error = '故事还没准备好，点一下再试';
        _loading = false;
      });
    }
  }

  /// 慢速版：同一段故事用 0.75 倍语速重新合成，本地缓存避免重复请求。
  Future<void> _playSlow() async {
    final cached = _slowAudio[_roleId];
    if (cached != null && cached.isNotEmpty) {
      _playAudio(cached);
      return;
    }
    if (_loadingSlow) return;
    setState(() => _loadingSlow = true);
    try {
      final story = await _api.fetchBedtimeStory(
        childId: widget.childId,
        roleId: _roleId,
        slow: true,
      );
      if (!mounted) return;
      _slowAudio[_roleId] = story.audioB64;
      _playAudio(story.audioB64);
    } catch (e) {
      AppLog.w('story', '慢速故事加载失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('慢速版暂时听不了，先听正常速度吧')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingSlow = false);
    }
  }

  void _playAudio(String audio) {
    if (audio.isEmpty) return;
    unawaited(
      _player
          .playBase64(audio)
          .catchError((Object e) => AppLog.w('story', '故事播放失败: $e')),
    );
  }

  void _switchRole(Role role) {
    if (role.id == _roleId) return;
    unawaited(_player.stop());
    setState(() {
      _roleId = role.id;
      _story = null;
      _error = null;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0F172A), Color(0xFF1E1B4B), Color(0xFF312E81)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildAppBar(),
              Expanded(child: _buildBody()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
          ),
          const Expanded(
            child: Text(
              '🌙 睡前故事',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ),
          if (widget.roles.length > 1)
            PopupMenuButton<Role>(
              tooltip: '换一个声音',
              onSelected: _switchRole,
              color: const Color(0xFF1E1B4B),
              icon: const Icon(Icons.record_voice_over, color: Colors.white70),
              itemBuilder: (_) => [
                for (final r in widget.roles)
                  PopupMenuItem(
                    value: r,
                    child: Text(
                      '${r.name} 的声音',
                      style: TextStyle(
                        color: r.id == _roleId
                            ? const Color(0xFFFDE68A)
                            : Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFFDE68A)),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🌙', style: TextStyle(fontSize: 46)),
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _load,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFFDE68A),
                foregroundColor: const Color(0xFF1E1B4B),
                minimumSize: const Size(150, 46),
              ),
              child: const Text(
                '再试一次',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
      );
    }
    final story = _story;
    if (story == null || story.text.trim().isEmpty) {
      return const Center(
        child: Text('今晚没有故事，先睡个好觉吧', style: TextStyle(color: Colors.white70)),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 10, 22, 26),
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '${_role?.name ?? ''} 陪你入睡',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 18),
        _buildStoryText(story.text),
        const SizedBox(height: 26),
        Row(
          children: [
            Expanded(
              child: _storyButton(
                icon: Icons.play_arrow_rounded,
                label: '再听一遍',
                onTap: () {
                  final audio = story.audioB64;
                  if (audio.isNotEmpty) {
                    _playAudio(audio);
                  } else {
                    _load();
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _storyButton(
                icon: Icons.slow_motion_video_rounded,
                label: _loadingSlow ? '慢一点…' : '慢一点',
                busy: _loadingSlow,
                onTap: _playSlow,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Center(
          child: Text(
            '听完就闭上眼睛，晚安 🌛',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildStoryText(String text) {
    final lines = text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              line,
              style: TextStyle(
                color: _hasChinese(line)
                    ? const Color(0xFFFDE68A)
                    : Colors.white,
                fontSize: _hasChinese(line) ? 16 : 20,
                height: 1.55,
                fontWeight: _hasChinese(line)
                    ? FontWeight.w600
                    : FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  bool _hasChinese(String s) =>
      s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  Widget _storyButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool busy = false,
  }) {
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(icon, color: const Color(0xFFFDE68A), size: 22),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
