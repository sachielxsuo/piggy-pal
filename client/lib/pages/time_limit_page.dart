import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/child_stats.dart';
import '../models/time_limit.dart';
import '../services/api_client.dart';

/// 家长中心 · 时长管控：每天默认 10 分钟，到点对话页会温柔道别。
/// 也可以选「不限时」——周末家长在旁边陪护时不自动收尾。
class TimeLimitPage extends StatefulWidget {
  final String childId;

  const TimeLimitPage({super.key, required this.childId});

  @override
  State<TimeLimitPage> createState() => _TimeLimitPageState();
}

class _TimeLimitPageState extends State<TimeLimitPage> {
  static const int _defaultMinutes = TimeLimit.defaultMinutes;
  static const int _minMinutes = TimeLimit.minMinutes;
  static const int _maxMinutes = TimeLimit.maxMinutes;

  final ApiClient _api = ApiClient();
  // 0 表示不限时（家长陪同）
  int _minutes = _defaultMinutes;
  int _todayUsedSec = 0;
  bool _loading = true;

  bool get _unlimited => _minutes == 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt(TimeLimit.prefKey);
    try {
      final stats = await _api.fetchStats(widget.childId);
      _todayUsedSec = stats.today.durationSec;
    } catch (_) {
      // 离线也能改设置，今日用量显示 0
    }
    if (!mounted) return;
    setState(() {
      // 0 是「不限时」，其余按 5~60 分钟夹取
      _minutes = TimeLimit.normalize(saved);
      _loading = false;
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(TimeLimit.prefKey, _minutes);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_unlimited ? '已保存：不限时（家长陪同）' : '已保存：每天最多 $_minutes 分钟'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('时长管控'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Color(0x141E40AF), blurRadius: 12),
                    ],
                  ),
                  child: Column(
                    children: [
                      const Text(
                        '每天陪伴上限',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (_unlimited)
                        const Text(
                          '不限时',
                          style: TextStyle(
                            color: Color(0xFF16A34A),
                            fontSize: 44,
                            height: 1.2,
                            fontWeight: FontWeight.w900,
                          ),
                        )
                      else
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '$_minutes',
                              style: const TextStyle(
                                color: Color(0xFF1D4ED8),
                                fontSize: 56,
                                height: 1,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8, left: 4),
                              child: Text(
                                '分钟',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        ),
                      const SizedBox(height: 10),
                      if (_unlimited)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 4),
                          child: Text(
                            '不会自动道别，宝宝想聊多久都可以；\n结束仍由家长或宝宝自己点「结束」',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 12,
                              height: 1.6,
                            ),
                          ),
                        )
                      else ...[
                        Slider(
                          value: _minutes.toDouble(),
                          min: _minMinutes.toDouble(),
                          max: _maxMinutes.toDouble(),
                          divisions: (_maxMinutes - _minMinutes) ~/ 5,
                          label: '$_minutes 分钟',
                          onChanged: (v) =>
                              setState(() => _minutes = (v / 5).round() * 5),
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final m in [5, 10, 15, 20, 30])
                              ChoiceChip(
                                label: Text('$m 分钟'),
                                selected: _minutes == m,
                                onSelected: (_) => setState(() => _minutes = m),
                              ),
                          ],
                        ),
                      ],
                      const Divider(height: 26),
                      SwitchListTile(
                        value: _unlimited,
                        onChanged: (on) =>
                            setState(() => _minutes = on ? 0 : _defaultMinutes),
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          '不限时（家长陪同）',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: const Text(
                          '周末有家长看护时开启，宝宝想聊多久都行',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _buildTodayUsage(),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: _unlimited
                        ? const Color(0xFFF0FDF4)
                        : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _unlimited ? '不限时模式下' : '到点会发生什么？',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _unlimited
                            ? '· 对话页顶部显示「不限时」，不会自动道别\n'
                                  '· 宝宝想聊多久都可以，家长在旁边看着就行\n'
                                  '· 家长或宝宝点「结束」后，仍会正常统计今日时长 / 星星\n'
                                  '· 修改后，下一次进入陪伴页生效'
                            : '· 对话页顶部会显示剩余时间，最后 1 分钟提醒宝宝\n'
                                  '· 时间到后自动进入结束页，说再见并预告明天\n'
                                  '· 不会突然退出或黑屏，宝宝不会受惊吓\n'
                                  '· 修改后，下一次进入陪伴页生效',
                        style: const TextStyle(
                          color: Color(0xFF475569),
                          fontSize: 12,
                          height: 1.7,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 50,
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    child: const Text(
                      '保存设置',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildTodayUsage() {
    final limitSec = _minutes * 60;
    final ratio = limitSec == 0
        ? 0.0
        : (_todayUsedSec / limitSec).clamp(0.0, 1.0);
    final reached = limitSec > 0 && _todayUsedSec >= limitSec;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '今日已陪伴',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
              Text(
                _unlimited
                    ? '${formatDuration(_todayUsedSec)} · 不限时'
                    : '${formatDuration(_todayUsedSec)} / $_minutes 分钟',
                style: TextStyle(
                  color: reached
                      ? const Color(0xFFEF4444)
                      : const Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 9,
              backgroundColor: const Color(0xFFE2E8F0),
              valueColor: AlwaysStoppedAnimation(
                reached ? const Color(0xFFEF4444) : const Color(0xFF1D4ED8),
              ),
            ),
          ),
          if (reached) ...[
            const SizedBox(height: 8),
            const Text(
              '今天已经达到上限，进入陪伴页会直接温柔道别',
              style: TextStyle(color: Color(0xFFEF4444), fontSize: 11),
            ),
          ],
          if (_unlimited) ...[
            const SizedBox(height: 8),
            const Text(
              '当前不限时，宝宝可以继续聊；家长可随时点「结束」',
              style: TextStyle(color: Color(0xFF16A34A), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
