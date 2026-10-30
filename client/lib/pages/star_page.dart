import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/child_stats.dart';
import '../services/api_client.dart';
import '../services/logger.dart';
import '../widgets/stats_widgets.dart';
import 'sticker_page.dart';

/// 星星奖励页：累计星星、近 7 天星星、连续打卡、最近 7 天明细。
class StarPage extends StatefulWidget {
  final String? childId;

  const StarPage({super.key, this.childId});

  @override
  State<StarPage> createState() => _StarPageState();
}

class _StarPageState extends State<StarPage> {
  final ApiClient _api = ApiClient();
  ChildStats? _stats;
  String _childId = '';
  String _childName = '';
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
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      _childId = widget.childId ?? prefs.getString('child_id') ?? '';
      _childName = prefs.getString('child_name') ?? '';
      if (_childId.isEmpty) {
        AppLog.i('stars', '未选择宝宝，星星页不请求数据');
        if (mounted) setState(() => _loading = false);
        return;
      }
      final stats = await _api.fetchStats(_childId);
      AppLog.i(
        'stars',
        '星星加载成功 child=$_childId week=${stats.weekStars} '
            'streak=${stats.streakDays}',
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
    } catch (e) {
      AppLog.w('stars', '加载星星数据失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '星星数据暂时拿不到，下拉重试一下';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('星星奖励'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_childId.isEmpty) {
      return _placeholder('先选一个宝宝，再来看星星吧', showBack: true);
    }
    if (_error != null) {
      return _placeholder(_error!, onRetry: _load);
    }
    final stats = _stats ?? ChildStats.empty(_childId);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _buildHeader(stats),
          const SizedBox(height: 10),
          _buildStickerEntry(),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.auto_awesome,
                  value: '${stats.weekStars}',
                  label: '近 7 天星星',
                  color: const Color(0xFFF59E0B),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.local_fire_department,
                  value: '${stats.streakDays}',
                  label: '连续天数',
                  color: const Color(0xFFEF4444),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.record_voice_over,
                  value: '${stats.totalUtterances}',
                  label: '累计开口',
                  color: const Color(0xFF10B981),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text(
              '说英文单词才能拿星星：1 个单词 1 颗，每轮最多 3 颗',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.replay,
                  value: '${stats.wordsToReview}',
                  label: '今日复习',
                  color: const Color(0xFF6366F1),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.workspace_premium,
                  value: '${stats.wordsMastered}',
                  label: '已掌握词',
                  color: const Color(0xFF0EA5E9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _card(
            title: '最近 7 天',
            child: WeekBarChart(days: stats.week),
          ),
          const SizedBox(height: 14),
          _card(
            title: '每日明细',
            child: Column(
              children: [
                for (var i = stats.week.length - 1; i >= 0; i--)
                  DayStatTile(
                    day: stats.week[i],
                    isToday: i == stats.week.length - 1,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          const Center(
            child: Text(
              '所有星星都记在服务端，换设备也不会丢',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  /// 贴纸墙入口：星星除了看数字，还能变成看得见的收藏。
  Widget _buildStickerEntry() {
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => StickerPage(childId: _childId)),
      ),
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: const [
            BoxShadow(color: Color(0x141E40AF), blurRadius: 12),
          ],
        ),
        child: const Row(
          children: [
            Text('🧩', style: TextStyle(fontSize: 26)),
            SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '我的贴纸墙',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '用攒到的星星解锁贴纸，星星不会被花掉',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Color(0xFF94A3B8)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ChildStats stats) {
    final who = _childName.isEmpty ? '我的' : '$_childName 的';
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFBBF24), Color(0xFFF59E0B)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [BoxShadow(color: Color(0x33F59E0B), blurRadius: 20)],
      ),
      child: Column(
        children: [
          Text(
            '$who星星罐',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 15,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text('⭐', style: TextStyle(fontSize: 32)),
              const SizedBox(width: 8),
              Text(
                '${stats.total.stars}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 56,
                  height: 1.05,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 10, left: 4),
                child: Text(
                  '颗',
                  style: TextStyle(color: Colors.white70, fontSize: 18),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '每一次开口，都值得一颗小星星',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  Widget _placeholder(
    String text, {
    bool showBack = false,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('⭐', style: TextStyle(fontSize: 44)),
          const SizedBox(height: 10),
          Text(text, style: const TextStyle(color: Color(0xFF64748B))),
          const SizedBox(height: 14),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: const Text('重新加载')),
          if (showBack)
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
        ],
      ),
    );
  }
}
