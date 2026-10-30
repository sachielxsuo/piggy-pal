import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../models/app_update.dart';
import '../services/app_updater.dart';
import '../services/logger.dart';

/// 家长在「关于 → 检查更新」手动触发的更新流程：
/// 检查版本 → 确认 → 下载 → 拉起系统安装器。
///
/// 启动时只做静默检查（[AppUpdater.checkSilently]），发现新版本仅在「关于」挂红点，
/// 不会自己弹窗打断宝宝。
Future<void> showAppUpdatePrompt(BuildContext context) async {
  AppUpdate? update;
  try {
    update = await AppUpdater.check();
  } catch (e) {
    AppLog.w('update', '检查更新失败: $e');
    if (context.mounted) _snack(context, '检查更新失败，看看网络后再试');
    return;
  }
  if (!context.mounted) return;

  if (update == null) {
    _snack(context, '已经是最新版本啦');
    return;
  }
  final latest = update;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => _UpdateDialog(update: latest),
  );
  if (go != true) return;
  if (!context.mounted) return;
  await _downloadAndInstall(context, latest);
}

Future<void> _downloadAndInstall(BuildContext context, AppUpdate update) async {
  final progress = ValueNotifier<double>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DownloadDialog(progress: progress, update: update),
    ).then((_) => dialogOpen = false),
  );

  File apk;
  try {
    apk = await AppUpdater.download(
      update,
      onProgress: (p) => progress.value = p,
    );
  } catch (e) {
    AppLog.e('update', '下载安装包失败: $e');
    if (dialogOpen) navigator.pop();
    if (context.mounted) _snack(context, '下载失败，检查网络后再试');
    return;
  }
  if (dialogOpen) navigator.pop();
  if (!context.mounted) return;

  final outcome = await AppUpdater.install(apk);
  if (!context.mounted) return;
  if (outcome == InstallOutcome.started) {
    _snack(context, '请在系统安装界面点「安装」，完成后重新打开 PiggyPal');
    return;
  }
  if (outcome == InstallOutcome.permissionRequired) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要允许安装应用'),
        content: const Text(
          '已经帮你打开设置页：找到「PiggyPal」并打开「允许安装未知应用」。\n\n'
          '授权后返回 App 会自动继续安装，安装包已经下载好，不会重新下载。',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  _snack(context, '安装没有启动成功，稍后再试一次');
}

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
  );
}

class _UpdateDialog extends StatelessWidget {
  final AppUpdate update;

  const _UpdateDialog({required this.update});

  @override
  Widget build(BuildContext context) {
    final changelog = update.changelog.trim();
    return AlertDialog(
      title: Text('发现新版本 v${update.versionName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            changelog.isEmpty ? '稳定性与体验优化' : changelog,
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
          if (update.sizeLabel.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              '安装包 ${update.sizeLabel}',
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            update.force ? '这次更新是必要的，更新完就能继续陪宝宝玩啦。' : '更新后宝宝的对话记录和星星都会保留。',
            style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('立即更新'),
        ),
      ],
    );
  }
}

class _DownloadDialog extends StatelessWidget {
  final ValueNotifier<double> progress;
  final AppUpdate update;

  const _DownloadDialog({required this.progress, required this.update});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('正在下载新版本'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, _) {
            final percent = (value * 100).clamp(0, 100).toStringAsFixed(0);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: value <= 0 ? null : value),
                const SizedBox(height: 10),
                Text(
                  '已完成 $percent%'
                  '${update.sizeLabel.isEmpty ? '' : ' · 共 ${update.sizeLabel}'}',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  '请保持网络连接，下载完成后会跳到系统安装界面。',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
