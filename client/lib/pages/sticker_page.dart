import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sticker.dart';
import '../services/api_client.dart';
import '../services/logger.dart';

/// 贴纸墙：按累计星星解锁，不消费星星。
/// 4-6 岁孩子不需要认识字，靠大 Emoji + 是否点亮就能理解进度。
class StickerPage extends StatefulWidget {
  final String? childId;

  const StickerPage({super.key, this.childId});

  @override
  State<StickerPage> createState() => _StickerPageState();
}

class _StickerPageState extends State<StickerPage> {
  final ApiClient _api = ApiClient();
  String _childId = '';
  StickerBoard? _board;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_childId.isEmpty) {
        final prefs = await SharedPreferences.getInstance().timeout(
          const Duration(seconds: 5),
        );
        _childId = widget.childId ?? prefs.getString('child_id') ?? '';
      }
      if (_childId.isEmpty) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final board = await _api.fetchStickers(_childId);
      AppLog.i(
        'stickers',
        '贴纸墙加载 total=${board.totalStars} '
            'unlocked=${board.unlockedCount}/${board.stickers.length}',
      );
      if (!mounted) return;
      setState(() {
        _board = board;
        _loading = false;
      });
    } catch (e) {
      AppLog.w('stickers', '贴纸墙加载失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '贴纸暂时拿不到，点一下重试吧';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('贴纸墙'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_childId.isEmpty) {
      return _message('先选一个宝宝，再来收集贴纸吧');
    }
    if (_error != null) {
      return _message(_error!, onRetry: _load);
    }
    final board = _board ?? const StickerBoard(childId: '');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _buildHeader(board),
          const SizedBox(height: 14),
          _buildNextHint(board),
          const SizedBox(height: 14),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: board.stickers.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 0.82,
            ),
            itemBuilder: (_, i) => _StickerTile(sticker: board.stickers[i]),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              '星星只要攒到就会解锁，不会被花掉哦',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(StickerBoard board) {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF818CF8), Color(0xFF6366F1)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [BoxShadow(color: Color(0x336366F1), blurRadius: 20)],
      ),
      child: Column(
        children: [
          const Text(
            '我的贴纸收藏',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('⭐', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 6),
              Text(
                '${board.totalStars}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 44,
                  height: 1.05,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 8, left: 4),
                child: Text(
                  '颗星星',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '已解锁 ${board.unlockedCount} / ${board.stickers.length} 张',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildNextHint(StickerBoard board) {
    final next = board.next;
    if (next == null) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Row(
          children: [
            Text('🏆', style: TextStyle(fontSize: 26)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '所有贴纸都集齐啦，你太厉害了！',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }
    final remaining = (next.stars - board.totalStars).clamp(0, next.stars);
    // 进度条按「上一张门槛 → 这一张门槛」计算，看起来更有盼头
    final prev = board.stickers
        .where((s) => s.unlocked)
        .fold<int>(0, (m, s) => s.stars > m ? s.stars : m);
    final span = (next.stars - prev).clamp(1, next.stars);
    final ratio = ((board.totalStars - prev) / span).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(next.emoji, style: const TextStyle(fontSize: 26)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '再攒 $remaining 颗星星，解锁「${next.name}」',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: const AlwaysStoppedAnimation(Color(0xFF6366F1)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(String text, {VoidCallback? onRetry}) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🧩', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(color: Color(0xFF64748B))),
          const SizedBox(height: 14),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: const Text('重新加载')),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}

class _StickerTile extends StatelessWidget {
  final Sticker sticker;

  const _StickerTile({required this.sticker});

  @override
  Widget build(BuildContext context) {
    final unlocked = sticker.unlocked;
    return Semantics(
      label: unlocked
          ? '已解锁 ${sticker.name}'
          : '${sticker.name}，需要 ${sticker.stars} 颗星星',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        decoration: BoxDecoration(
          color: unlocked ? Colors.white : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: unlocked ? const Color(0xFFC7D2FE) : const Color(0xFFE2E8F0),
          ),
          boxShadow: unlocked
              ? const [BoxShadow(color: Color(0x141E40AF), blurRadius: 8)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              unlocked ? sticker.emoji : '🔒',
              style: TextStyle(
                fontSize: unlocked ? 34 : 26,
                color: unlocked ? null : const Color(0xFF94A3B8),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              sticker.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: unlocked
                    ? const Color(0xFF1E3A8A)
                    : const Color(0xFF94A3B8),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              unlocked ? '已解锁' : '${sticker.stars} ⭐',
              style: TextStyle(
                color: unlocked
                    ? const Color(0xFF22C55E)
                    : const Color(0xFF94A3B8),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
