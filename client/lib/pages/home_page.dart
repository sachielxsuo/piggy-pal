import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/child_stats.dart';
import '../models/role.dart';
import '../services/api_client.dart';
import '../services/app_updater.dart';
import '../services/audio_player.dart';
import '../services/logger.dart';
import '../widgets/bob.dart';
import '../widgets/role_avatar.dart';
import '../widgets/update_badge.dart';
import 'about_page.dart';
import 'bedtime_story_page.dart';
import 'chat_page.dart';
import 'child_select_page.dart';
import 'parent_center_page.dart';
import 'star_page.dart';
import 'sticker_page.dart';

class HomePage extends StatefulWidget {
  /// 测试注入用；生产为 null，走服务端 /roles。
  final List<Role>? initialRoles;
  const HomePage({super.key, this.initialRoles});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final PageController _controller = PageController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final ApiClient _api = ApiClient();
  final AudioPlayerService _greeter = AudioPlayerService();

  /// 角色语音按 role_id 缓存在内存里，切换回来不重复下载。
  final Map<String, String> _greetAudio = {};

  /// 每次播放自增，防止快速切换角色时旧音频「后到先播」。
  int _greetSeq = 0;

  /// 有已选宝宝、首页真正可见时才播语音，避免在选宝宝页后面突然出声。
  bool _canGreet = false;

  /// 进入角色页只自动播一次；从对话页返回不再重复。
  bool _greetedOnce = false;
  int _index = 0;
  String _childId = '';
  String _childName = '';
  String _childAvatar = '';
  List<Role> _roles = [];
  bool _rolesLoading = true;
  int _weekStars = 0;
  // 今天的进度：家长每天真正关心的是「今天玩了多少、拿了几颗」
  int _todayStars = 0;
  int _todaySec = 0;
  // 今日计划词进度：只统计本周计划内的词
  int _todayPlanWords = 0;
  int _todayWordsHeard = 0;
  int _todayWordsSaid = 0;
  String _versionLabel = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadChild();
    _loadRoles();
    _loadVersion();
    unawaited(_checkUpdate());
  }

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

  /// 启动 2 秒后静默检查更新：只在「关于」挂个红点，不弹窗、不打断宝宝。
  Future<void> _checkUpdate() async {
    // 组件测试不走真实网络
    if (widget.initialRoles != null) return;
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    await AppUpdater.checkSilently();
  }

  /// 去开完「安装未知应用」权限回到 App：自动继续安装。
  Future<void> _retryPendingInstall() async {
    final outcome = await AppUpdater.retryPendingInstall();
    if (!mounted || outcome == null) return;
    if (outcome == InstallOutcome.started) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请在系统安装界面点「安装」完成更新')));
      return;
    }
    if (outcome == InstallOutcome.permissionRequired) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('还需要允许 PiggyPal 安装应用'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: '去设置',
            onPressed: () => unawaited(AppUpdater.openInstallSettings()),
          ),
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台 / 切走时别再自顾自说话
    if (state != AppLifecycleState.resumed) _stopGreeting();
    if (state == AppLifecycleState.resumed) {
      unawaited(_retryPendingInstall());
    }
  }

  /// 拉本周星星，用于抽屉和顶部小徽章。
  Future<void> _loadStats() async {
    // initialRoles 是测试注入标记：widget 测试里不发起真实网络请求
    if (widget.initialRoles != null) return;
    if (_childId.isEmpty) return;
    try {
      final stats = await _api.fetchStats(_childId);
      if (mounted) {
        setState(() {
          _weekStars = stats.weekStars;
          _todayStars = stats.today.stars;
          _todaySec = stats.today.durationSec;
          _todayPlanWords = stats.today.planWords;
          _todayWordsHeard = stats.today.wordsHeard;
          _todayWordsSaid = stats.today.wordsSaid;
        });
      }
      AppLog.i(
        'home',
        '本周星星加载成功 week=${stats.weekStars} '
            'today=${stats.today.stars} todaySec=${stats.today.durationSec}',
      );
    } catch (e) {
      AppLog.w('home', '加载本周星星失败: $e');
    }
    // 顺带预热本周学习计划：首页停留时生成好，进对话页就不用等。
    unawaited(_warmupLearningPlan());
  }

  Future<void> _warmupLearningPlan() async {
    if (widget.initialRoles != null || _childId.isEmpty) return;
    try {
      await _api.fetchLearningPlan(_childId);
    } catch (e) {
      AppLog.w('home', '预取学习计划失败: $e');
    }
  }

  /// 角色加载失败时的重试：孩子只认大按钮，不要让他对着「暂无数据」发呆。
  Future<void> _retryRoles() async {
    if (_rolesLoading) return;
    setState(() => _rolesLoading = true);
    await _loadRoles();
  }

  /// 从服务端拉角色列表（/roles），角色数据不再写死在前端。
  Future<void> _loadRoles() async {
    if (widget.initialRoles != null && widget.initialRoles!.isNotEmpty) {
      setState(() {
        _roles = widget.initialRoles!;
        _rolesLoading = false;
      });
      return;
    }
    try {
      final list = await _api.fetchRoles();
      AppLog.i('home', '角色列表加载成功 count=${list.length}');
      if (mounted) {
        setState(() {
          _roles = list;
          _rolesLoading = false;
        });
        // 提前把语音取回来，切角色时才能立刻出声
        unawaited(_prefetchGreetings());
        _maybeGreetOnEnter();
      }
    } catch (e) {
      AppLog.w('home', '角色列表加载失败: $e');
      if (mounted) setState(() => _rolesLoading = false);
    }
  }

  Future<void> _loadChild() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
      );
      final id = prefs.getString('child_id');
      final name = prefs.getString('child_name');
      final avatar = prefs.getString('child_avatar');
      if (mounted) {
        setState(() {
          _childId = id ?? '';
          _childName = name ?? '';
          _childAvatar = avatar ?? '';
          // 有宝宝且首页真正可见时才自动播角色语音
          _canGreet = (id ?? '').isNotEmpty;
        });
      }
    } catch (e) {
      // 本地缓存异常也不能卡住首页，按「还没选宝宝」处理
      AppLog.w('home', '读取宝宝缓存失败: $e');
    }
    // 首次进入、还没选过宝宝 → 直接进入选宝宝流程
    if (_childId.isEmpty && mounted) {
      await _pickChild();
    } else if (_childId.isNotEmpty) {
      _maybeGreetOnEnter();
      await _loadStats();
    }
  }

  Future<void> _pickChild() async {
    _stopGreeting();
    await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ChildSelectPage()));
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString('child_id');
    final name = prefs.getString('child_name');
    final avatar = prefs.getString('child_avatar');
    if (mounted && id != null && id.isNotEmpty) {
      setState(() {
        _childId = id;
        _childName = name ?? '';
        _childAvatar = avatar ?? '';
        _canGreet = true;
      });
      // 选完宝宝回到角色页 → 让角色打个招呼
      _maybeGreetOnEnter();
      await _loadStats();
    }
  }

  /// 首页可见时播放当前角色的自我介绍。只自动播一次，从对话页返回不再重复。
  void _maybeGreetOnEnter() {
    if (_greetedOnce || !_canGreet || _rolesLoading || _roles.isEmpty) return;
    _greetedOnce = true;
    unawaited(_playGreeting(_index));
  }

  /// 预取所有角色的语音：首次合成需要 1-2 秒，提前取好，切角色时立即出声。
  Future<void> _prefetchGreetings() async {
    if (widget.initialRoles != null) return; // widget 测试不发起真实网络请求
    for (final role in _roles) {
      if (_greetAudio.containsKey(role.id)) continue;
      try {
        final audio = (await _api.fetchRoleGreeting(role.id)).audioB64;
        if (audio.isNotEmpty) _greetAudio[role.id] = audio;
      } catch (e) {
        AppLog.w('home', '角色语音预取失败 role=${role.id}: $e');
      }
    }
  }

  /// 播放角色语音：中文自我介绍 + 英文口号；快速切角色时打断上一条。
  Future<void> _playGreeting(int i) async {
    if (widget.initialRoles != null) return; // widget 测试不发起真实网络请求
    if (!_canGreet || i < 0 || i >= _roles.length) return;
    final role = _roles[i];
    final seq = ++_greetSeq;
    await _greeter.stop();
    if (!mounted || seq != _greetSeq) return;

    var audio = _greetAudio[role.id];
    if (audio == null) {
      try {
        audio = (await _api.fetchRoleGreeting(role.id)).audioB64;
      } catch (e) {
        AppLog.w('home', '角色语音获取失败 role=${role.id}: $e');
        return;
      }
      if (audio.isEmpty) return;
      _greetAudio[role.id] = audio;
      if (!mounted || seq != _greetSeq) return;
    }
    try {
      await _greeter.playBase64(audio);
      AppLog.i('home', '角色语音播放 role=${role.id}');
    } catch (e) {
      AppLog.w('home', '角色语音播放失败 role=${role.id}: $e');
    }
  }

  /// 离开首页时立即停止语音，避免盖住下一个页面的声音。
  void _stopGreeting() {
    _greetSeq++;
    unawaited(_greeter.stop());
  }

  void _openParent() {
    _stopGreeting();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ParentCenterPage()))
        // 家长中心里可能切了开发者模式，回来刷新版本号展示
        .then((_) => _loadVersion());
  }

  Future<void> _openStars() async {
    _stopGreeting();
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => StarPage(childId: _childId)));
    await _loadStats();
  }

  /// 贴纸墙：按累计星星解锁，不消费星星。
  Future<void> _openStickers() async {
    _stopGreeting();
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StickerPage(childId: _childId)),
    );
  }

  /// 睡前故事：用当前角色音色读一段，晚上作为固定仪式。
  Future<void> _openBedtimeStory() async {
    _stopGreeting();
    if (_roles.isEmpty) {
      await _retryRoles();
      if (!mounted || _roles.isEmpty) return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BedtimeStoryPage(
          childId: _childId,
          roles: _roles,
          initialRoleId: _roles[_index % _roles.length].id,
        ),
      ),
    );
  }

  Future<void> _openAbout() async {
    _stopGreeting();
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AboutPage()));
    await _loadVersion();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopGreeting();
    _greeter.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    if (_roles.isEmpty) return;
    setState(() => _index = (i + _roles.length) % _roles.length);
    _controller.animateToPage(
      _index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFF8EC5FC),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          _buildScene(),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                Expanded(child: _buildSwiper()),
                _buildBottom(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 顶部栏 =====
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 抽屉里有没看过的更新时，一级入口也亮红点（家长很难注意到二级菜单）
          _circleBtn(
            Icons.menu,
            () => _scaffoldKey.currentState!.openDrawer(),
            badge: true,
          ),
          const Text(
            '英语陪伴',
            style: TextStyle(
              color: Color(0xFF1E40AF),
              fontWeight: FontWeight.w800,
              fontSize: 15,
              letterSpacing: 2,
            ),
          ),
          InkWell(
            onTap: _openStars,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(999),
                boxShadow: const [
                  BoxShadow(color: Color(0x241E40AF), blurRadius: 12),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('⭐', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text(
                    '$_weekStars',
                    style: const TextStyle(
                      color: Color(0xFFF59E0B),
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 睡前故事：月亮按钮，孩子一眼能认出来
          InkWell(
            onTap: _openBedtimeStory,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.8),
                shape: BoxShape.circle,
                boxShadow: const [
                  BoxShadow(color: Color(0x241E40AF), blurRadius: 12),
                ],
              ),
              child: const Text('🌙', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 沉浸式场景背景 =====
  Widget _buildScene() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 草地（底层）
          Positioned(
            left: -80,
            right: -80,
            bottom: -90,
            child: Container(
              height: 200,
              decoration: const BoxDecoration(
                color: Color(0xFFC8EFD4),
                borderRadius: BorderRadius.vertical(top: Radius.circular(300)),
              ),
            ),
          ),
          Positioned(
            left: -120,
            right: -120,
            bottom: -40,
            child: Container(
              height: 190,
              decoration: const BoxDecoration(
                color: Color(0xFFA7E3B8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(300)),
              ),
            ),
          ),
          // 太阳
          Positioned(
            top: 60,
            right: 40,
            child: Container(
              width: 84,
              height: 84,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xFFFEF3C7), Color(0xFFFBBF24)],
                ),
              ),
            ),
          ),
          // 云
          _cloud(110, 120, 0.9, 34),
          _cloud(60, 210, 0.8, 22),
        ],
      ),
    );
  }

  Widget _cloud(double top, double left, double opacity, double w) {
    return Positioned(
      top: top,
      left: left,
      child: Opacity(
        opacity: opacity,
        child: Row(children: [_circle(44), _circle(30), _circle(24)]),
      ),
    );
  }

  Widget _circle(double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
    );
  }

  // ===== 角色 swiper =====
  Widget _buildSwiper() {
    if (_rolesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_roles.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('🐷', style: TextStyle(fontSize: 46)),
            const SizedBox(height: 8),
            const Text(
              '小猪还没醒过来',
              style: TextStyle(
                color: Color(0xFF1E3A8A),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _retryRoles,
              icon: const Icon(Icons.refresh, size: 20),
              label: const Text(
                '再试一次',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1D4ED8),
                minimumSize: const Size(160, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        PageView.builder(
          controller: _controller,
          itemCount: _roles.length,
          onPageChanged: (i) {
            setState(() => _index = i);
            // 切到哪个角色就播哪个角色的自我介绍 + 英文口号
            unawaited(_playGreeting(i));
          },
          itemBuilder: (_, i) => _roleSlide(_roles[i]),
        ),
        // 左右箭头
        Align(alignment: Alignment.centerLeft, child: _arrowBtn(false)),
        Align(alignment: Alignment.centerRight, child: _arrowBtn(true)),
      ],
    );
  }

  Widget _arrowBtn(bool right) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.55),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x331E40AF), blurRadius: 14),
          ],
        ),
        child: IconButton(
          icon: Icon(
            right ? Icons.chevron_right : Icons.chevron_left,
            color: Colors.white,
            size: 28,
          ),
          onPressed: () => _goTo(right ? _index + 1 : _index - 1),
        ),
      ),
    );
  }

  Widget _roleSlide(Role role) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Flexible(
          child: Center(
            child: Bob(
              child: RoleAvatar(role: role, height: 300),
            ),
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              role.name,
              style: const TextStyle(
                color: Color(0xFF1E40AF),
                fontWeight: FontWeight.w800,
                fontSize: 26,
              ),
            ),
            Text(
              role.en,
              style: const TextStyle(
                color: Color(0xFFEC4899),
                fontWeight: FontWeight.w700,
                fontSize: 14,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          role.catchphrase,
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 15),
        ),
        const SizedBox(height: 10),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 40),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(999),
            boxShadow: const [
              BoxShadow(color: Color(0x1A1E40AF), blurRadius: 14),
            ],
          ),
          child: Text(
            role.sayEn,
            style: const TextStyle(
              color: Color(0xFF1E40AF),
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ===== 底部按钮 =====
  Widget _buildBottom() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 20),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1D4ED8),
                padding: const EdgeInsets.symmetric(vertical: 17),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              onPressed: () async {
                if (_roles.isEmpty) {
                  unawaited(_retryRoles());
                  return;
                }
                if (_childId.isEmpty) {
                  await _pickChild();
                  if (_childId.isEmpty || !mounted) return;
                }
                _stopGreeting();
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        ChatPage(role: _roles[_index], childId: _childId),
                  ),
                );
                await _loadStats();
              },
              child: const Text(
                '✨ 开始陪伴',
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
          ),
          // 今日进度：不用进星星页，家长一眼看到今天已经玩了多少
          if (_todayStars > 0 || _todaySec > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 13,
                    color: Color(0xFFF59E0B),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '今天 $_todayStars 颗 · 已玩 ${formatDuration(_todaySec)}',
                    style: const TextStyle(
                      color: Color(0xFF1D4ED8),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          if (_todayPlanWords > 0)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '今日单词 听到 $_todayWordsHeard/$_todayPlanWords · 说出 $_todayWordsSaid/$_todayPlanWords',
                style: const TextStyle(
                  color: Color(0xFF059669),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            '说英文单词就能拿星星 ⭐ · 全正向鼓励',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap, {bool badge = false}) {
    final button = Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        shape: BoxShape.circle,
        boxShadow: const [BoxShadow(color: Color(0x241E40AF), blurRadius: 12)],
      ),
      child: Icon(icon, color: const Color(0xFF1D4ED8), size: 22),
    );
    return InkWell(
      onTap: onTap,
      child: badge ? UpdateBadge(size: 10, child: button) : button,
    );
  }

  // ===== 抽屉（二级入口） =====
  Widget _buildDrawer() {
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.72,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: const Color(0xFFDBEAFE),
                    child: Text(
                      _childAvatar.isEmpty ? '👨‍👩‍👧' : _childAvatar,
                      style: const TextStyle(fontSize: 22),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _childName.isEmpty ? '宝宝成长空间' : '$_childName 的成长空间',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const Text(
                        '家庭 · 自用版',
                        style: TextStyle(
                          color: Color(0xFF64748B),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _drawerItem('🔐', '家长中心', 'PIN 进入 ›', _openParent, badge: true),
            _drawerItem(
              '👶',
              '选宝宝',
              _childName.isEmpty ? '选择 ›' : '$_childName ›',
              _pickChild,
            ),
            const Divider(height: 24),
            _drawerItem(
              '⭐',
              '星星奖励',
              _weekStars > 0 ? '近 7 天 $_weekStars 颗 ›' : '查看 ›',
              _openStars,
            ),
            _drawerItem('🌙', '睡前故事', '听一段再睡 ›', _openBedtimeStory),
            _drawerItem('🧩', '贴纸墙', '用星星解锁贴纸 ›', _openStickers),
            _drawerItem(
              'ℹ️',
              '关于',
              _versionLabel.isEmpty ? '查看 ›' : '$_versionLabel ›',
              _openAbout,
              badge: true,
              updateHint: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _drawerItem(
    String icon,
    String title,
    String sub,
    VoidCallback onTap, {
    bool badge = false,
    bool updateHint = false,
  }) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFFDBEAFE),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(icon, style: const TextStyle(fontSize: 18)),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: badge
          ? ValueListenableBuilder<bool>(
              valueListenable: AppUpdater.availableUpdate.badge,
              builder: (_, hasBadge, _) {
                final update = AppUpdater.availableUpdate.value;
                // 没看过时直接写「有新版本」，比只挂个红点更好懂
                final showNew = updateHint && hasBadge && update != null;
                return UpdateBadge(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 4, top: 2),
                    child: Text(
                      showNew ? '有新版本 v${update.versionName} ›' : sub,
                      style: TextStyle(
                        color: showNew
                            ? const Color(0xFFEF4444)
                            : const Color(0xFF64748B),
                        fontSize: 12,
                        fontWeight: showNew ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                );
              },
            )
          : Text(
              sub,
              style: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
            ),
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
    );
  }
}
