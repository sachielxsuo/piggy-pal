import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_update.dart';
import '../services/app_updater.dart';
import '../services/logger.dart';

/// 强制更新闸门：包住 App 首页，监听 [AppUpdater.forceUpdate]。
///
/// 低于最低版本时弹一个关不掉的对话框（返回键、点外部都不行），
/// 只有「立即更新」和「退出 App」两条路。启动、回到前台、每次心跳都会重新判定，
/// 装完新版本后自然就不再弹。
///
/// 没网时不拦人：拿不到 latest.json 就不知道最低版本，宁可让宝宝先用着，
/// 也不能因为服务端不可达把 App 变砖。
class ForceUpdateGate extends StatefulWidget {
  final Widget child;

  const ForceUpdateGate({super.key, required this.child});

  @override
  State<ForceUpdateGate> createState() => _ForceUpdateGateState();
}

class _ForceUpdateGateState extends State<ForceUpdateGate>
    with WidgetsBindingObserver {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppUpdater.forceUpdate.addListener(_maybeShow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppUpdater.forceUpdate.removeListener(_maybeShow);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统安装界面回来：重新判一次，装上了就放行
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  Future<void> _check() async {
    if (!mounted) return;
    await AppUpdater.checkSilently();
    if (mounted) _maybeShow();
  }

  void _maybeShow() {
    final update = AppUpdater.forceUpdate.value;
    if (update == null || _showing || !mounted) return;
    _showing = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ForceUpdateDialog(update: update),
    ).whenComplete(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 不可关闭的强制更新弹窗。抽成公开组件是为了能在测试里直接断言按钮和返回键行为。
class ForceUpdateDialog extends StatefulWidget {
  final AppUpdate update;

  /// 测试注入用；默认退出 App。
  final Future<void> Function()? onExit;

  const ForceUpdateDialog({super.key, required this.update, this.onExit});

  @override
  State<ForceUpdateDialog> createState() => _ForceUpdateDialogState();
}

class _ForceUpdateDialogState extends State<ForceUpdateDialog> {
  bool _busy = false;
  double _progress = 0;
  String? _error;
  String? _hint;
  File? _apk;

  Future<void> _exit() async {
    if (widget.onExit != null) {
      await widget.onExit!();
      return;
    }
    await SystemNavigator.pop();
  }

  Future<void> _startUpdate() async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
      _progress = 0;
    });

    // 已经下载好、只是还没装：直接再拉起安装器，不重新下 20MB
    if (_apk != null && await _apk!.exists()) {
      await _install(_apk!);
      return;
    }

    try {
      final apk = await AppUpdater.download(
        widget.update,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      _apk = apk;
      if (!mounted) return;
      await _install(apk);
    } catch (e) {
      AppLog.e('update', '强制更新下载失败: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '下载失败，检查一下网络再试';
      });
    }
  }

  Future<void> _install(File apk) async {
    final outcome = await AppUpdater.install(apk);
    if (!mounted) return;
    switch (outcome) {
      case InstallOutcome.started:
        setState(() {
          _busy = false;
          _hint = '已经打开系统安装界面，点「安装」完成后回到这里就好';
        });
      case InstallOutcome.permissionRequired:
        setState(() {
          _busy = false;
          _error = '需要允许「安装未知应用」，授权后回来点「再次安装」';
        });
      case InstallOutcome.failed:
        setState(() {
          _busy = false;
          _error = '安装没有启动成功，再试一次';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final update = widget.update;
    // canPop: false 挡住 Android 返回键；外部点击由 showDialog 的 barrierDismissible: false 挡住
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('需要更新一下才能继续'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '新版本 v${update.versionName} 已经准备好了。'
              '这次更新是必须的，宝宝的对话记录和星星都会保留。',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            if (_busy) ...[
              const SizedBox(height: 14),
              LinearProgressIndicator(value: _progress <= 0 ? null : _progress),
              const SizedBox(height: 8),
              Text(
                '正在下载 ${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%'
                '${update.sizeLabel.isEmpty ? '' : ' · 共 ${update.sizeLabel}'}',
                style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
              ),
            ],
            if (_hint != null) ...[
              const SizedBox(height: 12),
              Text(
                _hint!,
                style: const TextStyle(color: Color(0xFF2563EB), fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : _exit,
            child: const Text('退出'),
          ),
          FilledButton(
            onPressed: _busy ? null : _startUpdate,
            child: Text(
              _error != null
                  ? '再试一次'
                  : (_hint != null ? '再次打开安装' : '立即更新'),
            ),
          ),
        ],
      ),
    );
  }
}
