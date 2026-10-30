import 'package:flutter/material.dart';

import '../models/word_entry.dart';
import '../services/api_client.dart';
import '../services/logger.dart';
import '../services/word_cache.dart';

/// 点词弹出的词典卡片：音标 + 真人发音（正常 / 慢读）+ 释义 + 例句。
class WordSheet extends StatefulWidget {
  final String word;
  final String childId;
  final String roleId;

  /// 点击所在的消息 ID，用来取原句做语境例句。
  final int? msgId;

  /// 播放 base64 音频（复用聊天页的播放器，避免两个播放器抢音频焦点）。
  final Future<void> Function(String audioB64) onPlay;

  /// 测试 / 预览用：直接给一条结果就不再请求网络。
  final WordEntry? initialEntry;

  const WordSheet({
    super.key,
    required this.word,
    required this.childId,
    required this.roleId,
    required this.onPlay,
    this.msgId,
    this.initialEntry,
  });

  @override
  State<WordSheet> createState() => _WordSheetState();
}

class _WordSheetState extends State<WordSheet> {
  final ApiClient _api = ApiClient();

  WordEntry? _entry;
  bool _loading = true;
  String? _error;
  bool _autoPlayed = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialEntry != null) {
      _entry = widget.initialEntry;
      _loading = false;
      _maybeAutoPlay();
      return;
    }
    _load();
  }

  Future<void> _load() async {
    final cached = WordCache.get(widget.childId, widget.word);
    if (cached != null) {
      setState(() {
        _entry = cached;
        _loading = false;
      });
      _maybeAutoPlay();
      return;
    }
    try {
      final entry = await _api.fetchWordEntry(
        childId: widget.childId,
        word: widget.word,
        roleId: widget.roleId,
        msgId: widget.msgId,
      );
      WordCache.put(widget.childId, entry);
      if (!mounted) return;
      setState(() {
        _entry = entry;
        _loading = false;
      });
      _maybeAutoPlay();
    } catch (e) {
      AppLog.w('dict', '查词失败 word=${widget.word}: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '网络不太好，稍后再试试';
      });
    }
  }

  /// 打开就自动读一遍：孩子不识字，发音优先。
  void _maybeAutoPlay() {
    if (_autoPlayed) return;
    final audio = _entry?.audioB64;
    if (audio == null || audio.isEmpty) return;
    _autoPlayed = true;
    widget.onPlay(audio).catchError((Object e) {
      AppLog.w('dict', '播放单词发音失败: $e');
    });
  }

  Future<void> _play(String? audio) async {
    if (audio == null || audio.isEmpty) return;
    try {
      await widget.onPlay(audio);
    } catch (e) {
      AppLog.w('dict', '播放单词发音失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 6),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            )
          else if (_error != null)
            _buildMessage(_error!, action: _retry)
          else if (_entry == null || !_entry!.found)
            _buildMessage('这个词还没学会，换一个试试吧～')
          else
            _buildEntry(_entry!),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final entry = _entry;
    final display = entry?.lemma.isNotEmpty == true ? entry!.lemma : widget.word;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                display,
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  height: 1.15,
                ),
              ),
              if (entry != null &&
                  entry.phonetic.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  entry.phonetic,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 14,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
              if (entry != null && entry.isInflected) ...[
                const SizedBox(height: 2),
                Text(
                  '${entry.word} → ${entry.lemma}',
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 11.5,
                  ),
                ),
              ],
            ],
          ),
        ),
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded, color: Color(0xFF94A3B8)),
          iconSize: 20,
          visualDensity: VisualDensity.compact,
          tooltip: '关闭',
        ),
      ],
    );
  }

  Widget _buildEntry(WordEntry entry) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (entry.hasAudio) _buildAudioRow(entry),
        if (entry.senses.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionTitle('意思'),
          const SizedBox(height: 6),
          ...entry.senses.map(
            (s) => Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                s,
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 17,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
        if (entry.context != null) ...[
          const SizedBox(height: 14),
          _buildSentenceCard('在这句话里', entry.context!, const Color(0xFFEFF6FF),
              const Color(0xFF1D4ED8)),
        ],
        if (entry.example != null) ...[
          const SizedBox(height: 10),
          _buildSentenceCard('例句', entry.example!, const Color(0xFFF0FDF4),
              const Color(0xFF059669)),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            _badge(
              entry.audioSource == 'human' ? '真人发音' : '合成发音',
              entry.audioSource == 'human'
                  ? const Color(0xFF059669)
                  : const Color(0xFF94A3B8),
            ),
            if (entry.audioCredit != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.audioCredit!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 9.5),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildAudioRow(WordEntry entry) {
    final slow = entry.audioSlowB64 ?? entry.audioB64;
    return Row(
      children: [
        Expanded(
          child: _audioButton(
            label: '正常',
            icon: Icons.volume_up_rounded,
            audio: entry.audioB64,
            filled: true,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _audioButton(
            label: '慢读',
            icon: Icons.slow_motion_video_rounded,
            audio: slow,
            filled: false,
          ),
        ),
      ],
    );
  }

  Widget _audioButton({
    required String label,
    required IconData icon,
    required String? audio,
    required bool filled,
  }) {
    final color = const Color(0xFF1D4ED8);
    return SizedBox(
      height: 46,
      child: filled
          ? FilledButton.icon(
              onPressed: () => _play(audio),
              style: FilledButton.styleFrom(backgroundColor: color),
              icon: Icon(icon, size: 19),
              label: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            )
          : OutlinedButton.icon(
              onPressed: () => _play(audio),
              style: OutlinedButton.styleFrom(
                foregroundColor: color,
                side: const BorderSide(color: Color(0xFFC7D7FE)),
              ),
              icon: Icon(icon, size: 19),
              label: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
    );
  }

  Widget _buildSentenceCard(
      String title, WordSentence s, Color bg, Color accent) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: accent,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            s.en,
            style: const TextStyle(
              color: Color(0xFF1E293B),
              fontSize: 15.5,
              height: 1.4,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (s.zh != null) ...[
            const SizedBox(height: 3),
            Text(
              s.zh!,
              style: const TextStyle(
                color: Color(0xFF64748B),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(
        color: Color(0xFF94A3B8),
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 9.5, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _buildMessage(String text, {VoidCallback? action}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: 10),
            OutlinedButton(onPressed: action, child: const Text('重试')),
          ],
        ],
      ),
    );
  }

  void _retry() {
    setState(() {
      _loading = true;
      _error = null;
    });
    _load();
  }
}
