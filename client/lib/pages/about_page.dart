import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/env.dart';
import '../models/app_update.dart';
import '../services/api_client.dart';
import '../services/app_updater.dart';
import '../services/logger.dart';
import '../widgets/app_update_prompt.dart';
import '../widgets/update_badge.dart';

/// 关于页：版本信息、隐私说明、开源许可、运行日志导出 / 上传。
/// 长按或双击顶部图标可进入 / 退出开发者模式（本地开关，仅本机生效）。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  final ApiClient _api = ApiClient();
  bool _uploading = false;
  bool _devMode = false;
  String _versionLabel = '';

  @override
  void initState() {
    super.initState();
    _loadDevMode();
    _loadVersion();
    // 家长已经走到「关于」了：首页三横线和抽屉里的小红点一起消掉，
    // 但页面里的「发现新版本」文案仍保留，随时可以点「检查更新」。
    unawaited(AppUpdater.markSeen());
  }

  /// 版本号默认只显示 `v1.0.2`；开发者模式下才带上构建号 `(3)`。
  Future<void> _loadVersion() async {
    final prefs = await SharedPreferences.getInstance();
    final dev = prefs.getBool('dev_mode') ?? false;
    try {
      final label = await AppUpdater.currentVersionLabel(withBuild: dev);
      if (mounted) setState(() => _versionLabel = label);
    } catch (e) {
      AppLog.w('app', '读取版本号失败: $e');
    }
  }

  Future<void> _loadDevMode() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _devMode = prefs.getBool('dev_mode') ?? false);
  }

  /// 双击 / 长按切换开发者模式；关闭时如果当前选的是测试宝宝，顺手清掉选择。
  Future<void> _toggleDevMode() async {
    final prefs = await SharedPreferences.getInstance();
    final next = !(prefs.getBool('dev_mode') ?? false);
    await prefs.setBool('dev_mode', next);

    var clearedDevChild = false;
    if (!next) {
      final id = prefs.getString('child_id') ?? '';
      if (id.startsWith('dev_')) {
        await prefs.remove('child_id');
        await prefs.remove('child_name');
        await prefs.remove('child_avatar');
        clearedDevChild = true;
      }
    }
    if (!mounted) return;
    setState(() => _devMode = next);
    // 开关开发者模式时同步切换版本号展示（带不带构建号）
    unawaited(_loadVersion());
    AppLog.i('app', '开发者模式已${next ? '开启' : '关闭'}');
    final text = next
        ? '已进入开发者模式（再次长按 / 双击退出）'
        : (clearedDevChild ? '已退出开发者模式，并取消测试宝宝的选择' : '已退出开发者模式');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  /// 一键复制最近日志，家长不用连电脑、不用 ADB 就能把现场发过来。
  Future<void> _copyLogs() async {
    final messenger = ScaffoldMessenger.of(context);
    final text = await AppLog.recent();
    if (!mounted) return;
    if (text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('还没有日志，先操作一下再回来复制')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    final lines = text.split('\n').length;
    messenger.showSnackBar(SnackBar(content: Text('已复制最近 $lines 行日志，可直接粘贴发送')));
  }

  /// 上传最近 2 小时日志，服务端按文件名（起始时间）单独存放。
  Future<void> _uploadLogs() async {
    if (_uploading) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _uploading = true);
    try {
      final excerpt = await AppLog.excerpt();
      if (!mounted) return;
      if (excerpt.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('最近两小时没有日志')));
        return;
      }
      final name = await _api.uploadClientLog(
        filename: excerpt.fileName,
        content: excerpt.text,
      );
      AppLog.i('app', '日志已上传 server=$name lines=${excerpt.lineCount}');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('已上传 $name（${excerpt.lineCount} 行）')),
      );
    } catch (e) {
      AppLog.w('app', '日志上传失败: $e');
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('上传失败，检查网络后再试')));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F9FF),
      appBar: AppBar(
        title: const Text('关于'),
        backgroundColor: const Color(0xFFF4F9FF),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        children: [
          // 双击或长按这一块切开发者模式（不给孩子误触留提示，家长知道就行）
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: _toggleDevMode,
            onLongPress: _toggleDevMode,
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFBBF24), Color(0xFFF59E0B)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33F59E0B), blurRadius: 18),
                    ],
                  ),
                  child: const Text('🐷', style: TextStyle(fontSize: 40)),
                ),
                const SizedBox(height: 12),
                const Text(
                  'PiggyPal',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22),
                ),
                Text(
                  _versionLabel.isEmpty
                      ? '3-6 岁宝宝的英语陪伴玩伴'
                      : '3-6 岁宝宝的英语陪伴玩伴 · $_versionLabel',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 12,
                  ),
                ),
                if (_devMode) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE9FE),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bug_report_outlined,
                          size: 13,
                          color: Color(0xFF6D28D9),
                        ),
                        SizedBox(width: 4),
                        Text(
                          '开发者模式已开启',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF6D28D9),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          _section(
            '我们做什么',
            '用宝宝喜欢的卡通角色，陪宝宝用英语聊聊天、唱唱歌。'
                '每天默认 10 分钟，到点温柔道别，不用屏幕换安静。',
          ),
          _section(
            '隐私说明',
            '宝宝档案和陪伴统计只保存在家庭自建的服务器上，不接入任何广告或第三方统计。'
                '录音只用于当次语音识别，不会在服务器落盘保存。',
          ),
          _section(
            '给家长的话',
            '星星只奖不罚，不排名、不比较。宝宝不说话也没关系，'
                '沉默期也是语言学习的一部分。',
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              boxShadow: const [
                BoxShadow(color: Color(0x141E40AF), blurRadius: 12),
              ],
            ),
            child: Column(
              children: [
                // 点这里才走更新流程：检查 → 确认 → 下载 → 系统安装
                ValueListenableBuilder<AppUpdate?>(
                  valueListenable: AppUpdater.availableUpdate,
                  builder: (_, update, _) {
                    final hasUpdate = update != null;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.system_update_alt),
                      title: const Text('检查更新'),
                      subtitle: Text(
                        hasUpdate
                            ? '发现新版本 v${update.versionName}，点这里更新'
                            : (_versionLabel.isEmpty
                                  ? '正在读取当前版本…'
                                  : '当前 $_versionLabel'),
                        style: hasUpdate
                            ? const TextStyle(
                                color: Color(0xFFEF4444),
                                fontSize: 13,
                              )
                            : null,
                      ),
                      trailing: UpdateBadge(
                        child: Icon(
                          Icons.chevron_right,
                          color: hasUpdate ? const Color(0xFFEF4444) : null,
                        ),
                      ),
                      onTap: () => showAppUpdatePrompt(context),
                    );
                  },
                ),
                const Divider(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.code),
                  title: const Text('开源许可'),
                  subtitle: const Text('查看 Flutter 与第三方组件许可'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'PiggyPal',
                    applicationVersion: _versionLabel,
                  ),
                ),
                const Divider(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('运行日志'),
                  subtitle: Text(
                    AppLog.dirPath.isEmpty
                        ? '复制最近 500 行 · 上传最近 2 小时到服务器'
                        : '${AppLog.dirPath}\n复制最近 500 行 · 上传最近 2 小时到服务器',
                    style: const TextStyle(fontSize: 11),
                  ),
                  isThreeLine: AppLog.dirPath.isNotEmpty,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '复制日志',
                        onPressed: _uploading ? null : _copyLogs,
                        icon: const Icon(Icons.copy, size: 20),
                      ),
                      IconButton(
                        tooltip: '上传最近两小时日志',
                        onPressed: _uploading ? null : _uploadLogs,
                        icon: _uploading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.cloud_upload_outlined, size: 20),
                      ),
                    ],
                  ),
                  onTap: _uploading ? null : _copyLogs,
                ),
                const Divider(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('服务地址'),
                  subtitle: Text(
                    Env.apiBaseUrl,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          _section(
            '词典与发音来源',
            '中文释义来自 ECDICT（MIT），音标来自 CMU Pronouncing Dictionary（BSD-2）'
            '与 ipa-dict（MIT），英文例句为本项目为儿童改写。'
            '约 1000 个高频儿童词的发音为 Wikimedia Commons 上的真人录音，'
            '按 CC BY-SA 3.0 / CC BY 3.0 / CC0 等许可使用，'
            '每个词条内标注了录音作者与许可；慢读由同一段录音变速生成。',
          ),
          const Center(
            child: Text(
              'Made for our little one ♥',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, String body) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [BoxShadow(color: Color(0x141E40AF), blurRadius: 12)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              color: Color(0xFF475569),
              fontSize: 12.5,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}
