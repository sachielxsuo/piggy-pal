import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/logger.dart';

/// 家长中心内的「运行日志」页：App 内直接查看日志 + 一键复制，摆脱 adb。
class LogPage extends StatefulWidget {
  const LogPage({super.key});

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final text = await AppLog.readAll();
    if (!mounted) return;
    setState(() {
      _content = text;
      _loading = false;
    });
  }

  Future<void> _copy() async {
    if (_content.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已复制到剪贴板')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('运行日志'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          IconButton(icon: const Icon(Icons.copy), onPressed: _copy),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _content.isEmpty
              ? const Center(child: Text('暂无日志'))
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    _content,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12, height: 1.4),
                  ),
                ),
    );
  }
}
