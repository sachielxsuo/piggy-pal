import 'package:flutter/material.dart';

import '../models/child_stats.dart';

/// 一个指标卡（图标 + 数值 + 说明），星星页和家长报告共用。
class StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;

  const StatTile({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    this.color = const Color(0xFF1D4ED8),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// 计划词进度条：标签 + 进度 + 分数，报告页和结束页共用。
class WordProgressBar extends StatelessWidget {
  final String label;
  final int value;
  final int total;
  final Color color;
  final double labelWidth;

  const WordProgressBar({
    super.key,
    required this.label,
    required this.value,
    required this.total,
    this.color = const Color(0xFF3B82F6),
    this.labelWidth = 96,
  });

  @override
  Widget build(BuildContext context) {
    final safeTotal = total < 0 ? 0 : total;
    final safeValue = value.clamp(0, safeTotal);
    final ratio = safeTotal == 0 ? 0.0 : safeValue / safeTotal;
    return Row(
      children: [
        SizedBox(
          width: labelWidth,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 7,
              backgroundColor: const Color(0xFFEFF3FA),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          child: Text(
            '$safeValue/$safeTotal',
            textAlign: TextAlign.right,
            style: TextStyle(
              color: color,
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 最近 7 天星星柱状图（纯 Flutter 绘制，无第三方依赖）。
class WeekBarChart extends StatelessWidget {
  final List<DayStat> days;

  const WeekBarChart({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '还没有数据，先去陪宝宝聊几句吧',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
        ),
      );
    }
    final maxStars = days.fold<int>(1, (m, d) => d.stars > m ? d.stars : m);
    return SizedBox(
      height: 156,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: days.map((d) {
          final ratio = d.stars / maxStars;
          return Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  '${d.stars}',
                  style: const TextStyle(
                    color: Color(0xFFF59E0B),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 10 + ratio * 82,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xFFFBBF24), Color(0xFFFDE68A)],
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  d.weekdayLabel,
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// 单日明细行：日期 + 开口次数 / 陪伴时长 + 星星数。
class DayStatTile extends StatelessWidget {
  final DayStat day;
  final bool isToday;

  const DayStatTile({super.key, required this.day, this.isToday = false});

  @override
  Widget build(BuildContext context) {
    final title = isToday
        ? '今天 · ${day.weekdayLabel}'
        : '${day.weekdayLabel} ${day.shortDate}';
    final detail = day.utterances == 0 && day.durationSec == 0
        ? '这天还没有陪伴记录'
        : '开口 ${day.utterances} 次 · 陪伴 ${day.durationText}';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text('⭐', style: TextStyle(fontSize: 17)),
      ),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
      subtitle: Text(
        detail,
        style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
      ),
      trailing: Text(
        '${day.stars} 颗',
        style: const TextStyle(
          color: Color(0xFFF59E0B),
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }
}
