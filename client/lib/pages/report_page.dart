import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/child_stats.dart';
import '../models/learning_plan.dart';
import '../services/api_client.dart';
import '../services/logger.dart';
import '../widgets/stats_widgets.dart';

/// 家长中心 · 学习报告：时长 / 开口次数 / 星星 / 最近 7 天明细。
class ReportPage extends StatefulWidget {
  final String childId;

  const ReportPage({super.key, required this.childId});

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  final ApiClient _api = ApiClient();
  ChildStats? _stats;
  LearningPlan? _plan;
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
    final prefs = await SharedPreferences.getInstance();
    _childName = prefs.getString('child_name') ?? '';
    try {
      final stats = await _api.fetchStats(widget.childId);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _loading = false;
      });
      // 计划单独加载：首次要生成会慢几秒，不阻塞上面的统计先显示。
      // 失败也不影响整页报告，只是不展示单词卡片。
      try {
        final plan = await _api.fetchLearningPlan(widget.childId);
        if (mounted) setState(() => _plan = plan);
      } catch (e) {
        AppLog.w('report', '加载学习计划失败: $e');
      }
    } catch (e) {
      AppLog.w('report', '加载学习报告失败: $e');
      if (!mounted) return;
      setState(() {
        _error = '报告暂时拿不到，下拉重试一下';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('学习报告'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: const TextStyle(color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重新加载')),
          ],
        ),
      );
    }
    final stats = _stats ?? ChildStats.empty(widget.childId);
    final weekDuration = stats.week.fold<int>(
      0,
      (sum, d) => sum + d.durationSec,
    );
    final weekUtterances = stats.week.fold<int>(
      0,
      (sum, d) => sum + d.utterances,
    );
    final who = _childName.isEmpty ? '宝宝' : _childName;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          _buildTodayCard(who, stats),
          if (_plan != null && _plan!.today.words.isNotEmpty) ...[
            const SizedBox(height: 14),
            _buildTodayWordsCard(_plan!.today),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: StatTile(
                  icon: Icons.schedule,
                  value: formatDuration(weekDuration),
                  label: '近 7 天陪伴',
                  color: const Color(0xFF1D4ED8),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatTile(
                  icon: Icons.record_voice_over,
                  value: '$weekUtterances',
                  label: '近 7 天开口',
                  color: const Color(0xFF10B981),
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
            ],
          ),
          const SizedBox(height: 14),
          _card(
            title: '最近 7 天星星',
            child: WeekBarChart(days: stats.week),
          ),
          const SizedBox(height: 14),
          if (_plan != null && _plan!.days.isNotEmpty) ...[
            _card(title: '本周单词计划', child: _buildWeekPlan(_plan!)),
            const SizedBox(height: 14),
          ],
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
          const SizedBox(height: 14),
          _card(
            title: '累计',
            child: Column(
              children: [
                _kv('累计陪伴', formatDuration(stats.total.durationSec)),
                _kv('累计开口', '${stats.totalUtterances} 次'),
                _kv('累计星星', '${stats.total.stars} 颗'),
                _kv('累计打开', '${stats.total.openCount} 次'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Center(
            child: Text(
              '数据来自服务端陪伴记录，卸载重装也不会丢',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTodayCard(String who, ChildStats stats) {
    final today = stats.today;
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1D4ED8), Color(0xFF3B82F6)],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [BoxShadow(color: Color(0x331D4ED8), blurRadius: 20)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '今天 · $who',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatDuration(today.durationSec),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              const Text('⏱', style: TextStyle(fontSize: 26)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '开口 ${today.utterances} 次 · 星星 ${today.stars} 颗 · 打开 ${today.openCount} 次',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// 今日目标词：每个词三种状态——没出现（灰）、佩奇说过（蓝）、宝宝说过（绿）。
  Widget _buildTodayWordsCard(PlanDay today) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 14)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '今日单词',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
              const Spacer(),
              Text(
                '听到 ${today.heard}/${today.total} · 说出 ${today.said}/${today.total}',
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          WordProgressBar(
            label: '玩伴说给宝宝听',
            value: today.heard,
            total: today.total,
            color: const Color(0xFF3B82F6),
          ),
          const SizedBox(height: 6),
          WordProgressBar(
            label: '宝宝自己说出来',
            value: today.said,
            total: today.total,
            color: const Color(0xFF10B981),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final w in today.words) _wordChip(w, today)],
          ),
          const SizedBox(height: 8),
          const Text(
            '只统计本周计划内的单词，同一个词一天只算一次',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10.5),
          ),
        ],
      ),
    );
  }

  Widget _wordChip(PlanWord word, PlanDay today) {
    final said = today.hasSaid(word.en);
    final heard = today.hasHeard(word.en);
    final bg = said
        ? const Color(0xFFD1FAE5)
        : heard
        ? const Color(0xFFDBEAFE)
        : const Color(0xFFF1F5F9);
    final fg = said
        ? const Color(0xFF047857)
        : heard
        ? const Color(0xFF1D4ED8)
        : const Color(0xFF94A3B8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            word.en,
            style: TextStyle(
              color: fg,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 4),
          Text(word.zh, style: TextStyle(color: fg, fontSize: 10)),
          if (said) ...[
            const SizedBox(width: 3),
            const Text('✓', style: TextStyle(fontSize: 10, color: Color(0xFF047857))),
          ],
        ],
      ),
    );
  }

  /// 周一到周日：主题 + 每天听到 / 说出。
  Widget _buildWeekPlan(LearningPlan plan) {
    final today = plan.today.date;
    return Column(
      children: [
        for (final d in plan.days)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: d.date == today
                      ? const Color(0xFFDBEAFE)
                      : const Color(0xFFF1F5F9),
                  width: d.date == today ? 2 : 1,
                ),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Text(
                    d.weekdayLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: d.date == today
                          ? FontWeight.w800
                          : FontWeight.w600,
                      color: d.date == today
                          ? const Color(0xFF1D4ED8)
                          : const Color(0xFF475569),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    d.theme,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF334155)),
                  ),
                ),
                Text(
                  '听到 ${d.heard}/${d.total}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF3B82F6)),
                ),
                const SizedBox(width: 8),
                Text(
                  '说出 ${d.said}/${d.total}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF10B981)),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            '周一自动生成新一周计划',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 10),
          ),
        ),
      ],
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

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            k,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12.5),
          ),
          Text(
            v,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
