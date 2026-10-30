import 'package:flutter/material.dart';

import '../models/child_stats.dart';
import '../models/role.dart';
import '../services/api_client.dart';
import '../services/audio_player.dart';
import '../services/logger.dart';
import '../widgets/bob.dart';
import '../widgets/role_avatar.dart';
import '../widgets/stats_widgets.dart';

/// 结束页：道别 + 星星结算 + 预告明日（PRD 第 3 屏）。
class EndPage extends StatefulWidget {
  final Role role;
  final String childId;
  final int stars;
  final int durationSec;
  final String? sessionId;

  /// 今日学习计划完成情况（只统计计划内单词）。
  final int planWords;
  final int wordsHeard;
  final int wordsSaid;

  /// manual / time / daily_limit，用于文案区分。
  final String reason;

  const EndPage({
    super.key,
    required this.role,
    required this.childId,
    required this.stars,
    required this.durationSec,
    this.reason = 'manual',
    this.sessionId,
    this.planWords = 0,
    this.wordsHeard = 0,
    this.wordsSaid = 0,
  });

  @override
  State<EndPage> createState() => _EndPageState();
}

class _EndPageState extends State<EndPage> {
  final ApiClient _api = ApiClient();
  final AudioPlayerService _player = AudioPlayerService();

  String _goodbye = '';
  String? _audioB64;
  bool _loading = true;
  late int _stars = widget.stars;

  @override
  void initState() {
    super.initState();
    _loadGoodbye();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadGoodbye() async {
    try {
      final resp = await _api.goodbye(
        childId: widget.childId,
        roleId: widget.role.id,
        stars: widget.stars,
        sessionId: widget.sessionId,
      );
      if (!mounted) return;
      final text = (resp['reply_text'] ?? '').toString().trim();
      final audio = (resp['audio_b64'] ?? '').toString();
      final serverStars = (resp['stars'] as num?)?.toInt();
      setState(() {
        if (serverStars != null) _stars = serverStars;
        _goodbye = text.isEmpty ? _fallbackGoodbye() : text;
        _audioB64 = audio.isEmpty ? null : audio;
        _loading = false;
      });
      if (audio.isNotEmpty) {
        await _play(audio);
      }
    } catch (e) {
      AppLog.w('end', '加载结束页失败，使用本地兜底文案: $e');
      if (!mounted) return;
      setState(() {
        _goodbye = _fallbackGoodbye();
        _loading = false;
      });
    }
  }

  Future<void> _play(String audioB64) async {
    try {
      await _player.playBase64(audioB64);
    } catch (e) {
      AppLog.w('end', '播放道别语音失败: $e');
    }
  }

  String _fallbackGoodbye() {
    if (_stars > 0) {
      return '今天玩得真开心！你一共拿到 $_stars 颗小星星，太棒啦。'
          '明天我们再一起玩哦！';
    }
    return '今天玩得真开心！明天我们再一起玩哦！';
  }

  String get _reasonText {
    switch (widget.reason) {
      case 'time':
        return '时间到啦，今天先玩到这里～';
      case 'daily_limit':
        return '今天已经玩够啦，明天再来～';
      default:
        return '今天到这里啦～';
    }
  }

  void _replay() {
    final audio = _audioB64;
    if (audio == null || audio.isEmpty) return;
    _play(audio);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      body: Stack(
        children: [
          // 背景草地
          Positioned(
            left: -100,
            right: -100,
            bottom: -80,
            child: Container(
              height: 260,
              decoration: const BoxDecoration(
                color: Color(0xFFA7E3B8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(400)),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF1D4ED8)),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    children: [
                      Center(
                        child: Bob(
                          child: RoleAvatar(role: widget.role, height: 150),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: Text(
                          _reasonText,
                          style: const TextStyle(
                            color: Color(0xFF1E40AF),
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      _buildStarCard(),
                      if (widget.planWords > 0) ...[
                        const SizedBox(height: 16),
                        _buildPlanCard(),
                      ],
                      const SizedBox(height: 16),
                      _buildGoodbyeCard(),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 52,
                        child: FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1D4ED8),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          child: const Text(
                            '明天见 👋',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Center(
                        child: Text(
                          '休息一下眼睛，明天再来找我们玩吧',
                          style: TextStyle(
                            color: Color(0xFF64748B),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStarCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFBBF24), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x33F59E0B), blurRadius: 18)],
      ),
      child: Row(
        children: [
          const Text('⭐', style: TextStyle(fontSize: 40)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TweenAnimationBuilder<int>(
                  tween: IntTween(begin: 0, end: _stars),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => Text(
                    '今天获得 $value 颗星星',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '今天陪伴 ${formatDuration(widget.durationSec)} · '
                  '${widget.role.name}都记住啦',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 今日计划词完成度：听到 / 说出分开两条进度条。
  Widget _buildPlanCard() {
    final total = widget.planWords;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 14)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '今日单词计划',
                style: TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              Text(
                '计划 $total 个',
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '听和说分开统计，只算今天计划内的单词',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5),
          ),
          const SizedBox(height: 12),
          WordProgressBar(
            label: '听到（${widget.role.name}说）',
            value: widget.wordsHeard,
            total: total,
            color: const Color(0xFF3B82F6),
            labelWidth: 100,
          ),
          const SizedBox(height: 8),
          WordProgressBar(
            label: '说出（宝宝说）',
            value: widget.wordsSaid,
            total: total,
            color: const Color(0xFF10B981),
            labelWidth: 100,
          ),
          if (widget.wordsSaid >= total) ...[
            const SizedBox(height: 8),
            const Text(
              '今天的计划词全部说出来啦，太棒了！',
              style: TextStyle(
                color: Color(0xFF059669),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGoodbyeCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 14)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: const Color(0xFFDBEAFE),
                child: Text(
                  widget.role.name.isEmpty
                      ? '🐷'
                      : widget.role.name.substring(0, 1),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${widget.role.name}说',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
              const Spacer(),
              if (_audioB64 != null)
                TextButton.icon(
                  onPressed: _replay,
                  icon: const Icon(Icons.volume_up, size: 18),
                  label: const Text('再听一次'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else
            Text(
              _goodbye,
              style: const TextStyle(
                color: Color(0xFF1E293B),
                fontSize: 15,
                height: 1.7,
              ),
            ),
        ],
      ),
    );
  }
}
