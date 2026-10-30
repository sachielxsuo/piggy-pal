import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api_client.dart';
import '../widgets/update_badge.dart';
import 'about_page.dart';
import 'log_page.dart';
import 'report_page.dart';
import 'time_limit_page.dart';

class ParentCenterPage extends StatefulWidget {
  const ParentCenterPage({super.key});

  @override
  State<ParentCenterPage> createState() => _ParentCenterPageState();
}

class _ParentCenterPageState extends State<ParentCenterPage> {
  final ApiClient _api = ApiClient();
  final TextEditingController _pinCtrl = TextEditingController();
  bool _verified = false;
  bool _busy = false;
  String _childId = '';

  @override
  void initState() {
    super.initState();
    _loadChild();
  }

  Future<void> _loadChild() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _childId = prefs.getString('child_id') ?? '');
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    super.dispose();
  }

  void _openReport() {
    if (_childId.isEmpty) {
      _snack('先去首页选一个宝宝吧');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReportPage(childId: _childId)),
    );
  }

  void _openTimeLimit() {
    if (_childId.isEmpty) {
      _snack('先去首页选一个宝宝吧');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TimeLimitPage(childId: _childId)),
    );
  }

  Future<void> _enter() async {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) return;
    setState(() => _busy = true);
    try {
      final ok = await _api.verifyPin(pin);
      if (!mounted) return;
      if (ok) {
        setState(() => _verified = true);
      } else {
        _snack('PIN 错误，或还没设置过 PIN');
      }
    } catch (_) {
      _snack('网络连不上，稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setPin() async {
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('设置家长 PIN（至少 4 位）'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          obscureText: true,
          maxLength: 6,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (pin == null || pin.length < 4) return;
    setState(() => _busy = true);
    try {
      await _api.setPin(pin);
      if (mounted) {
        _snack('PIN 设置成功');
        setState(() => _verified = true);
      }
    } catch (_) {
      _snack('设置失败，稍后再试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('家长中心')),
      body: _verified ? _buildVerified() : _buildLock(),
    );
  }

  Widget _buildLock() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('🔐', style: TextStyle(fontSize: 48)),
          const SizedBox(height: 12),
          const Text(
            '输入家长 PIN 进入',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '****',
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _enter,
              child: const Text('进入'),
            ),
          ),
          TextButton(onPressed: _setPin, child: const Text('设置 / 重置 PIN')),
        ],
      ),
    );
  }

  Widget _buildVerified() {
    return ListView(
      children: [
        ListTile(
          leading: const Icon(Icons.bar_chart),
          title: const Text('学习报告'),
          subtitle: const Text('时长 / 开口次数 / 星星 / 最近 7 天'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openReport,
        ),
        ListTile(
          leading: const Icon(Icons.timer),
          title: const Text('时长管控'),
          subtitle: const Text('每天默认 10 分钟，周末可设不限时'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openTimeLimit,
        ),
        ListTile(
          leading: const Icon(Icons.article_outlined),
          title: const Text('查看日志'),
          subtitle: const Text('问题排查'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const LogPage()),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.settings),
          title: const Text('关于'),
          subtitle: const Text('版本信息 / 检查更新 / 开源许可'),
          // 有新版本时挂个红点，静默检查不会自己弹窗
          trailing: const UpdateBadge(child: Icon(Icons.chevron_right)),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AboutPage()),
          ),
        ),
      ],
    );
  }
}
