import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/daily_greeting.dart';
import '../models/message_page.dart';
import '../models/role.dart';
import '../models/target_word.dart';
import '../models/time_limit.dart';
import '../services/api_client.dart';
import '../services/audio_player.dart';
import '../services/audio_recorder.dart';
import '../services/chat_history_store.dart';
import '../services/heartbeat.dart';
import '../services/logger.dart';
import '../services/sfx_player.dart';
import '../widgets/bob.dart';
import '../widgets/role_avatar.dart';
import '../widgets/star_burst.dart';
import '../widgets/tappable_text.dart';
import '../widgets/today_word_strip.dart';
import '../widgets/typing_bubble.dart';
import '../widgets/word_popover.dart';
import '../widgets/word_sheet.dart';
import '../widgets/voice_wave.dart';
import 'end_page.dart';

class ChatPage extends StatefulWidget {
  final Role role;
  final String childId;
  const ChatPage({super.key, required this.role, required this.childId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const int _starGoal = 10;
  static const int _defaultLimitMin = 10;

  final List<ChatMsg> _messages = [];
  final TextEditingController _textCtrl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();
  final ApiClient _api = ApiClient();
  final ChatHistoryStore _historyStore = ChatHistoryStore();
  final AudioRecorderService _recorder = AudioRecorderService();
  final AudioPlayerService _player = AudioPlayerService();
  final SfxPlayer _sfx = SfxPlayer();

  final DateTime _startedAt = DateTime.now();

  /// 会话 ID 固定为「宝宝 + 角色」：同一个宝宝同一个角色始终是同一个会话，
  /// 聊天记录在一个线程里完整展示；剩余时长 / 星星仍按自然天统计。
  String get _sessionId => 'sess_${widget.childId}_${widget.role.id}';

  Timer? _ticker;
  Timer? _syncTimer;
  Timer? _gainTimer;
  Timer? _recordTimer;
  /// 录音剩余秒数（30 秒上限），用来给孩子一个「还能说多久」的预期，
  /// 避免说到一半被静默截断
  int _recordLeft = 0;
  // 本次会话累计星星（服务端 companion_session，用于防抖同步）
  int _sessionStars = 0;
  // 今日累计星星（服务端按自然天统计，顶部进度条 / 目标庆祝用）
  int _todayStars = 0;
  // 进入页面时今天已经用掉的时长，兜底展示今日累计时用
  int _todaySecAtStart = 0;
  int _lastSyncedStars = 0;
  int _lastGain = 0;
  // 历史分页：当前最早一条消息的 ID，以及是否还有更早的
  int _oldestId = 0;
  bool _hasMoreOlder = false;
  bool _loadingOlder = false;
  // 正在按消息 ID 拉语音的历史气泡（避免重复点击发多次 TTS）
  final Set<int> _loadingAudio = {};
  /// 正在加载「慢速版」语音的消息 ID（跟读用，服务端按 0.75 倍语速合成）
  final Set<int> _loadingSlowAudio = {};
  /// 慢速语音本地缓存，避免每次都往返服务端
  final Map<int, String> _slowAudioCache = {};
  /// 今日目标词卡片（顶部横向排列），点一下听发音
  List<TargetWord> _todayWords = const [];
  // 首次进页面滚到底之后才允许「上滑加载更早」，避免刚进来就误触翻页
  bool _readyForOlder = false;
  // 本次会话宝宝开口次数：用于判断今日话题语音要不要自动播（历史消息不算）
  int _sessionUtterances = 0;
  int _burstStars = 0;
  int _burstId = 0;
  String? _burstBadge;
  String? _burstSubtitle;
  bool _goalCelebrated = false;
  bool _englishHinted = false;
  String? _errorHint;
  String? _lastText;
  String? _lastAudioB64;
  // 分段 TTS 按到达顺序串行播放；_audioGen 变化时丢弃旧队列
  Future<void> _audioChain = Future.value();
  int _audioGen = 0;
  // 每次发送自增：回复文字先到时已经允许宝宝再说话，
  // 旧流晚到的回调 / 收尾不能把新一轮的发送状态清掉。
  int _sendSeq = 0;
  int _remainingSec = _defaultLimitMin * 60;
  bool _timerReady = false;
  // 倒计时语音预告：剩 2 分钟 / 30 秒各提醒一次，避免「突然结束」
  bool _warned2min = false;
  bool _warned30s = false;
  // 到点时正好在录音：先记下来，录完再播，避免被麦克风录进去
  String? _pendingWarning;
  // 家长在时长管控里选了「不限时」：不跑倒计时，也不自动收尾
  bool _unlimited = false;
  bool _finished = false;

  bool _listening = false;
  bool _sending = false;
  bool _showInput = false;

  /// 手指是否正按在说话按钮上；权限弹窗会打断按压，需要在开始录音前复查。
  bool _holding = false;
  bool _recording = false;

  /// 录音启动 / 停止的临界区标志，避免快速连按时 start 与 stop 交叠。
  bool _recordBusy = false;

  /// 按住说话时的实时音量，驱动按钮里的波形。
  final ValueNotifier<double> _voiceLevel = ValueNotifier(0);
  StreamSubscription<double>? _ampSub;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    // 提前装载得星音效，第一次得星不会有加载延迟
    unawaited(_sfx.preload());
    _initTimer();
    // 每 30 秒把本次陪伴时长报给服务端（幂等），进程被杀最多丢 30 秒
    Heartbeat.startSession(childId: widget.childId, sessionId: _sessionId);
    // 先回显历史对话，再取今日话题（当天首次会追加并自动播放）
    unawaited(_bootstrap());
    // 今日词卡：和计划一起加载，失败不打扰宝宝（对话照常）
    unawaited(_loadTodayWords());
  }

  /// 进入页面：本地缓存秒开 → 生成/取今日欢迎语 → 拉服务端历史（欢迎语已在里面）。
  /// 欢迎语不单独插气泡：服务端当天首次生成时会写进 chat_message，天然就是最新一条。
  Future<void> _bootstrap() async {
    await _loadLocalHistory();
    if (!mounted) return;
    final greeting = await _loadDailyGreeting();
    if (!mounted) return;
    await _loadHistory();
    if (!mounted || greeting == null) return;
    // 兜底：正常情况下欢迎语已在历史里；写入历史失败时也别让宝宝看不到
    await _ensureGreetingVisible(greeting);
    _maybePlayGreeting(greeting);
  }

  /// 先用本地最近 30 条把对话铺上，网络回来后再以服务端为准刷新。
  Future<void> _loadLocalHistory() async {
    final local = await _historyStore.load(
      childId: widget.childId,
      roleId: widget.role.id,
    );
    if (!mounted || local.isEmpty || _messages.isNotEmpty) return;
    setState(() => _messages.addAll(local));
    _scrollToBottom();
    AppLog.i('chat', '本地对话缓存回显 count=${local.length}');
  }

  /// 回显该宝宝与当前角色的历史对话（服务端按 child_id + role_id 落库）。
  /// 同一对宝宝 + 角色永远是一个会话，历史线程完整；先取最近一页，上滑再翻更早的。
  Future<void> _loadHistory() async {
    var page = MessagePage.empty;
    var ok = false;
    try {
      page = await _api.fetchMessages(
        childId: widget.childId,
        roleId: widget.role.id,
        limit: ChatHistoryStore.keep,
      );
      ok = true;
    } catch (e) {
      AppLog.w('chat', '历史对话加载失败，沿用本地缓存: $e');
    }
    final history = page.messages;
    if (!mounted) return;
    setState(() {
      if (ok && _sessionUtterances == 0 && !_sending) {
        // 服务端是最新权威数据，直接替换本地那份
        _messages
          ..clear()
          ..addAll(history);
      } else if (ok && history.isNotEmpty) {
        // 极端情况：历史回来前宝宝已经开口，只补本地没有的旧消息，别丢新消息
        final known = _messages.map((m) => '${m.who}|${m.text}').toSet();
        final missing = history
            .where((m) => !known.contains('${m.who}|${m.text}'))
            .toList();
        _messages.insertAll(0, missing);
      }
      if (ok) {
        _hasMoreOlder = page.hasMore;
        _oldestId = _firstMessageId() ?? _oldestId;
      }
      // 全新宝宝 / 清空过：给一句角色默认开场白，避免空白
      if (_messages.isEmpty) {
        _messages.add(ChatMsg(who: 'ai', text: widget.role.hello));
      }
    });
    _scrollToBottom();
    AppLog.i(
      'chat',
      '历史对话回显 count=${_messages.length} server=${history.length} '
          'ok=$ok hasMore=${page.hasMore} oldestId=$_oldestId',
    );
    unawaited(_persistHistory());
  }

  int? _firstMessageId() {
    for (final m in _messages) {
      if (m.id > 0) return m.id;
    }
    return null;
  }

  /// 上滑到顶部时，向服务端要更早的一页；插到顶部后修正滚动位置，视觉上不跳。
  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasMoreOlder || _oldestId <= 0) return;
    _loadingOlder = true;
    setState(() {});
    var oldMax = 0.0;
    if (_scrollCtrl.hasClients) oldMax = _scrollCtrl.position.maxScrollExtent;
    try {
      final page = await _api.fetchMessages(
        childId: widget.childId,
        roleId: widget.role.id,
        limit: ChatHistoryStore.keep,
        beforeId: _oldestId,
      );
      if (!mounted) return;
      setState(() {
        final known = _messages.map((m) => m.id).where((id) => id > 0).toSet();
        final older = page.messages
            .where((m) => m.id == 0 || !known.contains(m.id))
            .toList();
        if (older.isNotEmpty) _messages.insertAll(0, older);
        _hasMoreOlder = page.hasMore && older.isNotEmpty;
        _oldestId = _firstMessageId() ?? _oldestId;
        _loadingOlder = false;
      });
      // 顶部插入了 N 条，把视口往下推同样的高度，原来的内容不会跳走
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scrollCtrl.hasClients) return;
        final newMax = _scrollCtrl.position.maxScrollExtent;
        final target = (_scrollCtrl.position.pixels + (newMax - oldMax)).clamp(
          0.0,
          newMax,
        );
        _scrollCtrl.jumpTo(target);
      });
      AppLog.i(
        'chat',
        '加载更早消息 count=${page.messages.length} hasMore=${page.hasMore} '
            'oldestId=$_oldestId',
      );
    } catch (e) {
      AppLog.w('chat', '加载更早消息失败: $e');
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  void _onScroll() {
    if (!_readyForOlder || !_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.pixels > 120) return;
    if (!_hasMoreOlder || _loadingOlder || _oldestId <= 0) return;
    unawaited(_loadOlder());
  }

  /// 把当前对话的最近 30 条写到本地，下次进入秒开。
  Future<void> _persistHistory() async {
    try {
      await _historyStore.save(
        childId: widget.childId,
        roleId: widget.role.id,
        messages: _messages,
      );
    } catch (e) {
      AppLog.w('chat', '本地对话缓存失败: $e');
    }
  }

  /// 取今日欢迎语。当天首次调用时服务端会生成并写入聊天记录（最新一条），
  /// 之后直接复用；客户端只负责拿 isNew 决定要不要自动播。
  Future<DailyGreeting?> _loadDailyGreeting() async {
    try {
      final g = await _api.fetchDailyGreeting(
        childId: widget.childId,
        roleId: widget.role.id,
      );
      final textLen = g.text.trim().length;
      if (textLen == 0) return null;
      AppLog.i(
        'chat',
        '今日话题就绪 isNew=${g.isNew} textLen=$textLen '
            'audioLen=${g.audioB64.length}',
      );
      return g;
    } catch (e) {
      // 网络/服务端异常时沿用已有历史 / 默认开场白，不打扰宝宝
      AppLog.w('chat', '今日话题加载失败，沿用历史记录: $e');
      return null;
    }
  }

  /// 历史里没带上欢迎语（比如写库失败）时补一条，保证宝宝能看到。
  Future<void> _ensureGreetingVisible(DailyGreeting g) async {
    final text = g.text.trim();
    final shown = _messages.any((m) => m.who == 'ai' && m.text.trim() == text);
    if (shown) return;
    setState(() {
      _messages.add(
        ChatMsg(
          who: 'ai',
          text: text,
          audioB64: g.audioB64.isEmpty ? null : g.audioB64,
        ),
      );
    });
    _scrollToBottom();
    await _persistHistory();
  }

  /// 加载今日目标词卡；服务端已按当天进度填好听过 / 说过状态。
  Future<void> _loadTodayWords() async {
    try {
      final plan = await _api.fetchLearningPlan(widget.childId);
      if (!mounted) return;
      final today = plan.today;
      final words = today.words
          .map(
            (w) => TargetWord(
              en: w.en,
              zh: w.zh,
              heard: today.hasHeard(w.en),
              said: today.hasSaid(w.en),
            ),
          )
          .toList();
      setState(() => _todayWords = words);
      AppLog.i('chat', '今日词卡加载 count=${words.length}');
    } catch (e) {
      AppLog.w('chat', '今日词卡加载失败: $e');
    }
  }

  /// 点词卡 → 弹出词典（正常 / 慢读发音 + 例句），和点气泡里的单词一致。
  void _openTodayWord(TargetWord word) {
    unawaited(_player.stop());
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => WordSheet(
          word: word.en,
          childId: widget.childId,
          roleId: widget.role.id,
          onPlay: (b64) => _player.playBase64(b64),
        ),
      ),
    );
  }

  /// 当天首次生成、且本次会话还没开口时才自动播，避免打断宝宝。
  void _maybePlayGreeting(DailyGreeting g) {
    if (!g.isNew || g.audioB64.isEmpty) return;
    if (_sessionUtterances > 0 ||
        _sending ||
        _finished ||
        _listening ||
        _recording) {
      return;
    }
    _play(g.audioB64);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _syncTimer?.cancel();
    _gainTimer?.cancel();
    _recordTimer?.cancel();
    _ampSub?.cancel();
    // 页面退出时如果还在录音，停掉并丢弃，避免麦克风一直占用
    if (_recording) {
      _recording = false;
      unawaited(_recorder.stop().catchError((Object _) => null));
    }
    // 用户直接返回、没走结束页时，补报最终时长，并冲刷一次会话星星
    if (!_finished) {
      unawaited(Heartbeat.finishSession());
      unawaited(_syncSessionStars());
    }
    _textCtrl.dispose();
    _inputFocus.dispose();
    _scrollCtrl.dispose();
    _player.dispose();
    unawaited(_sfx.dispose());
    _voiceLevel.dispose();
    super.dispose();
  }

  /// 读取家长设置的每日上限 + 今天已用时长，算出本次剩余时间。
  /// `daily_limit_min = 0` 表示不限时（周末家长陪同），不启动倒计时。
  Future<void> _initTimer() async {
    final prefs = await SharedPreferences.getInstance();
    final rawLimit = prefs.getInt(TimeLimit.prefKey) ?? _defaultLimitMin;
    final limit = TimeLimit.isUnlimited(rawLimit)
        ? 0
        : rawLimit.clamp(1, 120).toInt();
    var usedSec = 0;
    var todayStars = 0;
    try {
      final stats = await _api.fetchStats(widget.childId);
      usedSec = stats.today.durationSec;
      todayStars = stats.today.stars;
    } catch (e) {
      AppLog.w('chat', '读取今日陪伴数据失败，按 0 处理: $e');
    }
    if (!mounted || _finished) return;

    final total = limit * 60;
    setState(() {
      _unlimited = limit == 0;
      _remainingSec = _unlimited ? 0 : (total - usedSec).clamp(0, total);
      _todaySecAtStart = usedSec;
      _todayStars = todayStars;
      // 今天已经拿过 10 颗了，本次就不再重复播放大目标庆祝
      _goalCelebrated = todayStars >= _starGoal;
      _timerReady = true;
    });
    if (_unlimited) {
      AppLog.i('chat', '家长设置为不限时，不启动每日倒计时');
      return;
    }
    if (_remainingSec <= 0) {
      // 今天已经玩够：直接温柔收尾
      await _finishSession(reason: 'daily_limit');
      return;
    }
    _ticker = Timer.periodic(const Duration(seconds: 1), _onTick);
  }

  void _onTick(Timer timer) {
    if (!mounted || _finished) {
      timer.cancel();
      return;
    }
    if (_remainingSec <= 1) {
      setState(() => _remainingSec = 0);
      timer.cancel();
      _finishSession(reason: 'time');
      return;
    }
    setState(() => _remainingSec--);
    _maybeWarnTimeLeft();
  }

  /// 剩 2 分钟 / 30 秒时播一句语音预告。
  /// 4-6 岁从「玩」切到「结束」需要缓冲，直接掐断很容易闹情绪。
  void _maybeWarnTimeLeft() {
    if (_unlimited || _finished) return;
    String? kind;
    // 用「小于等于」而不是「等于」：中途进来可能只剩 1 分多钟，
    // 或某次 tick 被系统延迟跳过，等于判断会漏掉提醒。
    if (!_warned30s && _remainingSec <= 30) {
      _warned30s = true;
      kind = '30s';
    } else if (!_warned2min && _remainingSec <= 120) {
      _warned2min = true;
      kind = '2min';
    }
    if (kind == null) return;
    if (_listening) {
      // 正在录音：等录完再播，不然会录进麦克风
      _pendingWarning = kind;
      return;
    }
    unawaited(_playTimeWarning(kind));
  }

  /// 拉服务端预置的提醒语音（固定文案，TTS 磁盘缓存，不额外花钱）。
  Future<void> _playTimeWarning(String kind) async {
    try {
      final resp = await _api.fetchTimeWarning(widget.role.id, kind);
      final audio = (resp['audio_b64'] ?? '').toString();
      if (audio.isEmpty) {
        AppLog.w('chat', '倒计时提醒没有语音，跳过 kind=$kind');
        return;
      }
      if (!mounted || _finished) return;
      // 提醒比正在播的回复更重要，直接打断
      await _player.stop();
      _play(audio);
      AppLog.i('chat', '播放倒计时提醒 kind=$kind');
    } catch (e) {
      AppLog.w('chat', '倒计时提醒失败: $e');
    }
  }

  /// 星星变化后防抖 1.2s 再同步，避免每轮都打接口。
  void _scheduleSessionSync() {
    _syncTimer?.cancel();
    _syncTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_syncSessionStars());
    });
  }

  /// 把本次会话星星的绝对值同步到服务端。
  /// 服务端只补差额，重复 / 延迟上报不会重复加星。
  Future<void> _syncSessionStars() async {
    final stars = _sessionStars;
    if (stars <= 0 || stars <= _lastSyncedStars) return;
    try {
      final serverStars = await _api.syncSession(
        widget.childId,
        sessionId: _sessionId,
        stars: stars,
      );
      if (serverStars > _lastSyncedStars) _lastSyncedStars = serverStars;
      AppLog.i('chat', '会话星星已同步 stars=$stars server=$serverStars');
    } catch (e) {
      AppLog.w('chat', '同步会话星星失败（下次重试）: $e');
    }
  }

  /// 结束本次陪伴：上报时长 → 取今日累计 → 进入结束页（道别 + 星星结算 + 预告明日）。
  /// 结束页展示的是「今天」的累计值，不是这一小段会话，避免刚进来就超时的时候显示 0。
  Future<void> _finishSession({String reason = 'manual'}) async {
    if (_finished) return;
    _finished = true;
    _ticker?.cancel();
    _syncTimer?.cancel();
    final seconds = DateTime.now().difference(_startedAt).inSeconds;
    // 先冲刷一次会话星星，结束页以服务端为准；失败也不阻塞跳转
    unawaited(_syncSessionStars());

    var todayStars = _todayStars;
    var todayDurationSec = _todaySecAtStart + seconds;
    // 今日计划词完成度：从同一份 stats 里取，不额外多打一次接口。
    var planWords = 0;
    var wordsHeard = 0;
    var wordsSaid = 0;
    try {
      // 必须等时长上报完再查统计，否则今日累计会少掉刚结束的这几分钟；
      // 网络慢时最多等 3 秒，超时就用本次会话数据兜底，不卡住道别页
      await Heartbeat.finishSession().timeout(const Duration(seconds: 3));
      final stats = await _api
          .fetchStats(widget.childId)
          .timeout(const Duration(seconds: 3));
      todayStars = stats.today.stars;
      todayDurationSec = stats.today.durationSec;
      planWords = stats.today.planWords;
      wordsHeard = stats.today.wordsHeard;
      wordsSaid = stats.today.wordsSaid;
    } catch (e) {
      AppLog.w('chat', '读取今日累计失败，结束页用本次会话数据: $e');
    }
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => EndPage(
          role: widget.role,
          childId: widget.childId,
          stars: todayStars,
          durationSec: todayDurationSec,
          planWords: planWords,
          wordsHeard: wordsHeard,
          wordsSaid: wordsSaid,
          reason: reason,
          sessionId: _sessionId,
        ),
      ),
    );
  }

  /// 退出聊天：不弹二次确认，直接上报并进入结束页。
  Future<void> _exitChat() async {
    if (_finished || !mounted) return;
    await _finishSession();
  }

  /// 播放 TTS 失败只记日志，不打断对话。
  void _play(String audioB64) {
    _player
        .playBase64(audioB64)
        .catchError((Object e) => AppLog.w('chat', '播放语音失败: $e'));
  }

  /// 重播一条 AI 消息：本次对话里的音频直接用；历史消息没有音频，
  /// 按消息 ID 向服务端取（服务端 TTS 有文本 + 音色缓存，重播不会重复合成）。
  ///
  /// slow=true 时向服务端要 0.75 倍语速版本：4-6 岁跟读时，慢速比重播更有效。
  Future<void> _replayMessage(ChatMsg m, {bool slow = false}) async {
    if (!slow && (m.audioB64?.isNotEmpty ?? false)) {
      _play(m.audioB64!);
      return;
    }
    if (m.id <= 0) {
      _noAudioHint();
      return;
    }
    if (slow) {
      final cached = _slowAudioCache[m.id];
      if (cached != null && cached.isNotEmpty) {
        _play(cached);
        return;
      }
    }
    final loading = slow ? _loadingSlowAudio : _loadingAudio;
    if (!loading.add(m.id)) return;
    setState(() {});
    try {
      final audio = await _api.fetchMessageAudio(
        childId: widget.childId,
        messageId: m.id,
        slow: slow,
      );
      if (!mounted) return;
      if (audio.isEmpty) {
        _noAudioHint();
        return;
      }
      if (slow) {
        _slowAudioCache[m.id] = audio;
      } else {
        final i = _messages.indexWhere((x) => x.id == m.id && x.who == 'ai');
        if (i >= 0) {
          setState(() => _messages[i] = _messages[i].copyWith(audioB64: audio));
        }
      }
      _play(audio);
    } catch (e) {
      AppLog.w('chat', '历史消息语音加载失败(slow=$slow): $e');
      if (mounted) _noAudioHint();
    } finally {
      if (mounted) setState(() => loading.remove(m.id));
    }
  }

  void _noAudioHint() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('这条语音暂时播不了，再和${widget.role.name}聊一句试试～'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 顶部喇叭：重播最近一条 AI 消息（历史消息按需向服务端取语音）。
  void _replayLast() {
    for (final m in _messages.reversed) {
      if (m.who == 'ai') {
        unawaited(_replayMessage(m));
        return;
      }
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('还没有可以重播的语音哦')));
  }

  /// 气泡里的语音小按钮：重播 / 慢一点。
  /// 内边距按 4-6 岁的点击容错放宽（视觉仍是小字，热区约 34×32）。
  Widget _audioAction({
    required IconData icon,
    required String label,
    required bool loading,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xFF1D4ED8),
                ),
              )
            else
              Icon(icon, size: 15, color: const Color(0xFF1D4ED8)),
            const SizedBox(width: 4),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF1D4ED8),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
      _readyForOlder = true;
    });
  }

  Future<bool> _ensureMic() async {
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
    }
    if (!status.isGranted && mounted) {
      final blocked = status.isPermanentlyDenied;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(blocked ? '麦克风权限被关掉了，去设置里打开就能说话啦' : '需要麦克风权限才能说话哦'),
          action: SnackBarAction(
            label: '去设置',
            onPressed: () {
              openAppSettings();
            },
          ),
        ),
      );
    }
    return status.isGranted;
  }

  void _onPressStart() {
    _holding = true;
    _startRecord();
  }

  void _onPressEnd() {
    _holding = false;
    _stopRecord();
  }

  Future<void> _startRecord() async {
    if (_sending || _finished || _recordBusy) return;
    if (!await _ensureMic()) return;
    // 先停掉正在播放的 TTS（含还在排队的分段语音），避免把佩奇的声音录进去
    _audioGen++;
    await _player.stop();
    // 首次授权会弹系统框，等回来时手指可能已经松开了
    if (!mounted || !_holding || _sending || _finished || _recordBusy) return;
    _recordBusy = true;
    setState(() {
      _listening = true;
      _recordLeft = 30;
    });
    AppLog.i('chat', '录音开始');
    try {
      await _recorder.start();
      _recording = true;
      _listenAmplitude();
      // 兜底：最多录 30 秒，不会一直录下去。
      // 用每秒 tick 而不是一次性 Timer：孩子能看到还剩几秒，不会说到一半被切断还不知道。
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!_recording) {
          t.cancel();
          return;
        }
        if (!mounted) return;
        setState(() {
          _recordLeft = _recordLeft > 0 ? _recordLeft - 1 : 0;
        });
        if (_recordLeft <= 0) _stopRecord();
      });
      // 录音启动过程中手指已经松开：立刻停掉，不发这段
      if (!_holding) {
        await _discardRecording();
      }
    } catch (e) {
      AppLog.e('chat', '录音启动失败: $e');
      _recording = false;
      if (!mounted) return;
      setState(() {
        _listening = false;
        _recordLeft = 0;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('麦克风没准备好，再试一次吧')));
    } finally {
      _recordBusy = false;
    }
  }

  /// 订阅实时音量，驱动「按住说话」按钮里的波形。
  void _listenAmplitude() {
    _ampSub?.cancel();
    _voiceLevel.value = 0;
    _ampSub = _recorder.amplitudeLevels().listen(
      (v) => _voiceLevel.value = v,
      // 拿不到音量时波形保持静止即可，不影响录音
      onError: (Object _) {},
    );
  }

  void _stopAmplitude() {
    _ampSub?.cancel();
    _ampSub = null;
    _voiceLevel.value = 0;
  }

  /// 丢弃当前录音（手指已松开 / 页面退出），不发送。
  Future<void> _discardRecording() async {
    if (!_recording) return;
    _recording = false;
    _recordTimer?.cancel();
    _stopAmplitude();
    try {
      await _recorder.stop();
    } catch (_) {
      // 忽略：这段录音本来就丢弃
    }
    if (!mounted) return;
    setState(() {
      _listening = false;
      _recordLeft = 0;
    });
  }

  Future<void> _stopRecord() async {
    if (!_recording) return;
    _recording = false;
    _recordTimer?.cancel();
    _stopAmplitude();
    String? path;
    _recordBusy = true;
    try {
      path = await _recorder.stop();
    } finally {
      _recordBusy = false;
    }
    if (!mounted) return;
    setState(() {
      _listening = false;
      _recordLeft = 0;
    });
    // 录音期间到点的提醒，现在补播
    final pending = _pendingWarning;
    if (pending != null) {
      _pendingWarning = null;
      unawaited(_playTimeWarning(pending));
    }
    if (path == null) {
      AppLog.w('chat', '录音停止但未得到文件（可能太短）');
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('说得太短啦，按住多说一会儿～')));
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      AppLog.i('chat', '录音结束 path=$path bytes=${bytes.length}');
      await _send(audioB64: base64Encode(bytes));
    } catch (e) {
      AppLog.e('chat', '读取录音失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('录音没保存好，再试一次吧')));
    }
  }

  void _sendText() {
    final v = _textCtrl.text.trim();
    if (v.isEmpty || _sending || _finished) return;
    _textCtrl.clear();
    // 发完收起键盘，让宝宝能马上看到回复
    FocusScope.of(context).unfocus();
    _send(text: v);
  }

  Future<void> _send({
    String? text,
    String? audioB64,
    bool retry = false,
  }) async {
    if (_finished || _sending) return;
    final seq = ++_sendSeq;
    _lastText = text;
    _lastAudioB64 = audioB64;
    if (!retry) _sessionUtterances++;
    // 新一轮开始：丢弃上一轮还没播完的分段音频
    _audioGen++;
    setState(() {
      _sending = true;
      _errorHint = null;
      // 打字输入先乐观上屏，宝宝不用等网络就有回应感
      if (!retry && text != null && text.trim().isNotEmpty) {
        _messages.add(ChatMsg(who: 'child', text: text.trim()));
      }
    });
    _scrollToBottom();
    AppLog.i(
      'chat',
      '发送对话 childId=${widget.childId} roleId=${widget.role.id} '
          'textLen=${text?.length ?? 0} audioLen=${audioB64?.length ?? 0}',
    );
    var gotReply = false;
    try {
      // 流式：ASR 完成先出宝宝气泡，LLM 完成再出佩奇气泡，语音按句陆续到达
      await _api.chatStream(
        childId: widget.childId,
        roleId: widget.role.id,
        text: text,
        audioB64: audioB64,
        sessionId: _sessionId,
        onEvent: (event, data) {
          if (!mounted || _finished || seq != _sendSeq) return;
          switch (event) {
            case 'asr':
              _onAsrStage((data['child_text'] ?? '').toString());
            case 'reply':
              gotReply = true;
              _onReplyStage(data);
            case 'audio':
              final audio = (data['audio_b64'] ?? '').toString();
              if (audio.isNotEmpty) _enqueueAudio(audio);
          }
        },
      );
    } catch (e, st) {
      AppLog.e('chat', '对话失败: $e\n$st');
      if (!mounted || seq != _sendSeq) return;
      // 文本已经出来的话不再报「没听清」，只是语音没播完
      if (!gotReply) {
        setState(() => _errorHint = '没听清呀，${widget.role.name}再等你说一次～');
        _scrollToBottom();
      }
    } finally {
      // 只有当前这一轮才能收尾；旧流结束不能把新发送的状态清掉
      if (mounted && seq == _sendSeq) {
        setState(() => _sending = false);
      }
    }
  }

  /// ASR 阶段：识别出宝宝说的话就立刻上屏，不用等 LLM / TTS。
  void _onAsrStage(String childText) {
    final t = childText.trim();
    if (t.isEmpty) return; // 没听清：等 reply 阶段的温和引导
    final last = _messages.isEmpty ? null : _messages.last;
    // 打字输入已乐观上屏 / 重试时重复的识别结果：不重复加气泡
    if (last != null && last.who == 'child' && last.text == t) return;
    setState(() => _messages.add(ChatMsg(who: 'child', text: t)));
    AppLog.i('chat', 'ASR 阶段上屏 "$t"');
    _scrollToBottom();
  }

  /// 回复阶段：佩奇气泡先出文字，语音稍后按句补上。
  void _onReplyStage(Map<String, dynamic> data) {
    final reply = (data['reply_text'] ?? '').toString();
    final stars = (data['stars'] as num?)?.toInt() ?? 0;
    final wordCount = (data['word_count'] as num?)?.toInt() ?? 0;
    final serverSessionStars = (data['session_stars'] as num?)?.toInt();
    final targetBonus = (data['target_bonus'] as num?)?.toInt() ?? 0;
    final targetWords = ((data['target_words'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => TargetWord.fromJson(e.cast<String, dynamic>()))
        .toList();
    AppLog.i(
      'chat',
      '收到回复 replyLen=${reply.length} stars=$stars words=$wordCount '
          'sessionStars=$serverSessionStars targetBonus=$targetBonus '
          'targets=${targetWords.length}',
    );
    setState(() {
      if (reply.isNotEmpty) {
        _messages.add(ChatMsg(who: 'ai', text: reply));
      }
      // 词卡状态以服务端为准：听过 / 说过 / 这一轮刚说中
      if (targetWords.isNotEmpty) _todayWords = targetWords;
      // 服务端返回的会话星星是权威值；旧服务端没有该字段时本地累加兜底
      if (serverSessionStars != null && serverSessionStars >= _sessionStars) {
        _sessionStars = serverSessionStars;
      } else {
        _sessionStars += stars;
      }
      if (stars > 0) {
        _todayStars += stars;
        _lastGain = stars;
        _burstStars = stars;
        _burstId++;
        // 今天第一次达到 10 颗小目标：换成更隆重的庆祝文案
        if (!_goalCelebrated && _todayStars >= _starGoal) {
          _goalCelebrated = true;
          _burstBadge = '$_starGoal 颗达成！';
          _burstSubtitle = '太厉害啦！';
        } else if (targetBonus > 0) {
          // 说中目标词：给一个明确的因果反馈，孩子才知道「刚刚说对了」
          _burstBadge = null;
          _burstSubtitle = '说中目标词 +$targetBonus 颗星！';
        } else {
          _burstBadge = null;
          _burstSubtitle = null;
        }
      }
      _errorHint = null;
      // 文字已到：立刻收起「佩奇正在想」，让宝宝能马上接话
      _sending = false;
      _lastText = null;
      _lastAudioB64 = null;
    });
    if (stars > 0) {
      unawaited(HapticFeedback.mediumImpact());
      // 达成 10 颗用更长的庆祝音，平时是短促的「叮」
      if (_burstBadge != null) {
        unawaited(_sfx.goal());
      } else {
        unawaited(_sfx.star());
      }
    }
    // 说中文 / 没说到英文单词：温和提示一次，不打断对话
    final heard = _lastChildText();
    if (wordCount == 0 && heard.isNotEmpty && !_englishHinted) {
      _englishHinted = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.role.name}听到啦～ 用英文说一个词就能拿星星，试试 '
            'apple！',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
    if (stars > 0) {
      _gainTimer?.cancel();
      _gainTimer = Timer(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _lastGain = 0);
      });
    }
    _scrollToBottom();
    // 防抖同步本次会话星星到服务端
    _scheduleSessionSync();
    // 本地保留最近 30 条，下次进入秒开
    unawaited(_persistHistory());
  }

  String _lastChildText() {
    for (final m in _messages.reversed) {
      if (m.who == 'child') return m.text;
    }
    return '';
  }

  /// 分段语音按到达顺序排队播放，避免多句 TTS 互相打断。
  void _enqueueAudio(String audioB64) {
    final gen = _audioGen;
    _audioChain = _audioChain.then((_) async {
      // 新一轮 / 宝宝开始说话后，旧语音直接丢弃
      if (!mounted || gen != _audioGen) return;
      try {
        await _player.playBase64(audioB64);
      } catch (e) {
        AppLog.w('chat', '播放分段语音失败: $e');
      }
    });
  }

  void _retrySend() {
    _send(text: _lastText, audioB64: _lastAudioB64, retry: true);
  }

  @override
  Widget build(BuildContext context) {
    final burstId = _burstId;
    return PopScope(
      canPop: _finished,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _exitChat();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F9FF),
        body: Stack(
          children: [
            Column(
              children: [
                _buildHero(),
                Expanded(child: _buildMessages()),
                _buildBottom(),
              ],
            ),
            // 得星动效：铺满全屏但不拦截触摸
            if (_burstStars > 0)
              Positioned.fill(
                child: StarBurst(
                  key: ValueKey(burstId),
                  stars: _burstStars,
                  badgeText: _burstBadge,
                  subtitle: _burstSubtitle,
                  onDone: () {
                    if (!mounted || burstId != _burstId) return;
                    setState(() => _burstStars = 0);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ===== 顶部沉浸头图 =====
  Widget _buildHero() {
    return SizedBox(
      height: 340,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: -30,
            child: Container(
              height: 130,
              decoration: const BoxDecoration(
                color: Color(0xFFA7E3B8),
                borderRadius: BorderRadius.vertical(top: Radius.circular(300)),
              ),
            ),
          ),
          Positioned(
            top: 108,
            right: 26,
            child: Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [Color(0xFFFEF3C7), Color(0xFFFBBF24)],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Center(
              child: Bob(
                distance: 4,
                child: RoleAvatar(role: widget.role, height: 172),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _circleBtn(Icons.arrow_back, _exitChat),
                      Text(
                        '${widget.role.name} ${widget.role.en}',
                        style: const TextStyle(
                          color: Color(0xFF1E40AF),
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                      _circleBtn(Icons.volume_up, _replayLast),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                  child: Row(
                    children: [
                      Expanded(child: _buildStarProgress()),
                      const SizedBox(width: 8),
                      _buildTimeChip(),
                      const SizedBox(width: 8),
                      _buildFinishBtn(),
                    ],
                  ),
                ),
                if (_todayWords.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TodayWordStrip(
                      words: _todayWords,
                      onTap: _openTodayWord,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部星星进度条：今天累计获得星星 / 小目标（按自然天，不随会话重置）。
  Widget _buildStarProgress() {
    final ratio = (_todayStars / _starGoal).clamp(0.0, 1.0);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x1A1E40AF), blurRadius: 10)],
      ),
      child: Row(
        children: [
          const Text('⭐', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: ratio),
                duration: const Duration(milliseconds: 520),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 7,
                  backgroundColor: const Color(0xFFE2E8F0),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFFF59E0B)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (_lastGain > 0) ...[
            Text(
              '+$_lastGain',
              style: const TextStyle(
                color: Color(0xFF16A34A),
                fontWeight: FontWeight.w800,
                fontSize: 11,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            '$_todayStars/$_starGoal',
            style: const TextStyle(
              color: Color(0xFFF59E0B),
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeChip() {
    final unlimited = _unlimited && _timerReady;
    final mm = (_remainingSec ~/ 60).toString().padLeft(2, '0');
    final ss = (_remainingSec % 60).toString().padLeft(2, '0');
    final warn = !unlimited && _timerReady && _remainingSec <= 60;
    final color = unlimited
        ? const Color(0xFF16A34A)
        : (warn ? const Color(0xFFDC2626) : const Color(0xFF1D4ED8));
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: warn
            ? const Color(0xFFFEE2E2)
            : Colors.white.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x1A1E40AF), blurRadius: 10)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            unlimited ? Icons.all_inclusive : Icons.timer_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            unlimited ? '不限时' : (_timerReady ? '$mm:$ss' : '--:--'),
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFinishBtn() {
    return InkWell(
      onTap: _exitChat,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.84),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x1A1E40AF), blurRadius: 10),
          ],
        ),
        child: const Icon(
          Icons.flag_outlined,
          size: 18,
          color: Color(0xFF1D4ED8),
        ),
      ),
    );
  }

  // ===== 消息流 =====
  Widget _buildMessages() {
    final extra = (_sending ? 1 : 0) + (_errorHint != null ? 1 : 0);
    final leading = _loadingOlder ? 1 : 0;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: leading + _messages.length + extra,
      itemBuilder: (_, i) {
        if (leading == 1 && i == 0) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final index = i - leading;
        if (index >= _messages.length) {
          if (_sending) {
            return TypingBubble(label: '${widget.role.name}正在想');
          }
          return _buildErrorBubble();
        }
        final m = _messages[index];
        final isAi = m.who == 'ai';
        final loadingAudio = isAi && _loadingAudio.contains(m.id);
        final loadingSlow = isAi && _loadingSlowAudio.contains(m.id);
        return Align(
          alignment: isAi ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 7),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            constraints: const BoxConstraints(maxWidth: 330),
            decoration: BoxDecoration(
              color: isAi ? Colors.white : const Color(0xFF1D4ED8),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(22),
                topRight: const Radius.circular(22),
                bottomLeft: Radius.circular(isAi ? 8 : 22),
                bottomRight: Radius.circular(isAi ? 22 : 8),
              ),
              boxShadow: const [
                BoxShadow(color: Color(0x141E40AF), blurRadius: 12),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: isAi
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: [
                _buildBubbleText(m.text, isAi, m.id),
                if (isAi)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _audioAction(
                          icon: Icons.volume_up,
                          label: '重播',
                          loading: loadingAudio,
                          onTap: () => _replayMessage(m),
                        ),
                        const SizedBox(width: 4),
                        _audioAction(
                          icon: Icons.slow_motion_video,
                          label: '慢一点',
                          loading: loadingSlow,
                          onTap: () => _replayMessage(m, slow: true),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 今日话题是「中文版 + 英文版」两行：英文行用蓝色加粗，家长一眼能看出两版都在。
  /// 英文单词可点，弹出词典卡片；中文和标点不响应。
  Widget _buildBubbleText(String text, bool isAi, int msgId) {
    final base = TextStyle(
      color: isAi ? const Color(0xFF1E293B) : Colors.white,
      fontSize: 16.5,
      height: 1.5,
    );
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    void onWord(String word, Rect rect) => _openWordPopover(word, rect, msgId);

    if (lines.length <= 1) {
      return TappableText(text: text, style: base, onWordTap: onWord);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < lines.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 6),
            child: TappableText(
              text: lines[i],
              style: isAi && _isEnglishLine(lines[i])
                  ? base.copyWith(
                      color: const Color(0xFF1D4ED8),
                      fontWeight: FontWeight.w600,
                    )
                  : base,
              onWordTap: onWord,
            ),
          ),
      ],
    );
  }

  /// 点英文单词 → 在单词上方弹出词典卡片，并顺手打断正在播的语音。
  void _openWordPopover(String word, Rect anchor, int msgId) {
    unawaited(_player.stop());
    unawaited(showWordPopover(
      context: context,
      anchor: anchor,
      builder: (_) => WordSheet(
        word: word,
        childId: widget.childId,
        roleId: widget.role.id,
        msgId: msgId > 0 ? msgId : null,
        onPlay: (b64) => _player.playBase64(b64),
      ),
    ));
  }

  /// 不含汉字的行按英文行处理（用于高亮显示）。
  bool _isEnglishLine(String line) =>
      !line.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  Widget _buildErrorBubble() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 7),
        padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
        constraints: const BoxConstraints(maxWidth: 330),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7ED),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(22),
            topRight: Radius.circular(22),
            bottomLeft: Radius.circular(8),
            bottomRight: Radius.circular(22),
          ),
          border: Border.all(color: const Color(0xFFFED7AA)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _errorHint ?? '没听清呀，${widget.role.name}再等你说一次～',
              style: const TextStyle(
                color: Color(0xFF9A3412),
                fontSize: 15,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: _sending ? null : _retrySend,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1D4ED8),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text(
                '再试一次',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 底部：同一行，按住说话 ⇄ 打字，右侧按钮切换 =====
  Widget _buildBottom() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  child: _showInput ? _buildTextInput() : _buildHoldToTalk(),
                ),
              ),
              const SizedBox(width: 10),
              _circleBtn(
                _showInput
                    ? Icons.mic_none_rounded
                    : Icons.keyboard_alt_outlined,
                _toggleInputMode,
                tooltip: _showInput ? '按住说话' : '打字',
              ),
            ],
          ),
          // 只在语音模式显示操作提示，打字模式下不占高度
          if (!_showInput) ...[
            const SizedBox(height: 8),
            const Text(
              '按住说话，松开发送',
              style: TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  /// 在「打字」和「按住说话」之间切换；切到打字时直接拉起键盘。
  void _toggleInputMode() {
    setState(() => _showInput = !_showInput);
    if (_showInput) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _inputFocus.requestFocus();
      });
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  Widget _buildHoldToTalk() {
    return Listener(
      key: const ValueKey('holdToTalk'),
      onPointerDown: (_) => _onPressStart(),
      onPointerUp: (_) => _onPressEnd(),
      onPointerCancel: (_) => _onPressEnd(),
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: _listening
              ? const Color(0xFFDC2626)
              : (_sending ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8)),
          minimumSize: const Size.fromHeight(56),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        onPressed: () {}, // 实际交互由 Listener 接管
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 160),
          child: _listening
              ? Row(
                  key: const ValueKey('listening'),
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    VoiceWave(level: _voiceLevel, color: Colors.white),
                    const SizedBox(width: 10),
                    const Text(
                      '松开就发送',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 剩余秒数：让 4-6 岁（和家长）知道还能说多久
                    Text(
                      '$_recordLeft 秒',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: _recordLeft <= 5
                            ? const Color(0xFFFDE68A)
                            : Colors.white70,
                      ),
                    ),
                  ],
                )
              : Text(
                  _sending ? '💭 ${widget.role.name}在想…' : '🎤 按住说话',
                  key: ValueKey(_sending),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
      ),
    );
  }

  /// 打字输入：发送键内嵌在输入框右侧，不再单独占一行。
  Widget _buildTextInput() {
    return TextField(
      key: const ValueKey('textInput'),
      controller: _textCtrl,
      focusNode: _inputFocus,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _sendText(),
      decoration: InputDecoration(
        hintText: '打字也可以哦…',
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.fromLTRB(18, 16, 4, 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _textCtrl,
          builder: (_, value, _) {
            final canSend = value.text.trim().isNotEmpty && !_sending;
            return IconButton(
              tooltip: '发送',
              onPressed: canSend ? _sendText : null,
              icon: const Icon(Icons.send_rounded, size: 22),
              color: const Color(0xFF1D4ED8),
            );
          },
        ),
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap, {String? tooltip}) {
    final btn = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(color: Color(0x1F1E40AF), blurRadius: 14),
          ],
        ),
        child: Icon(icon, color: const Color(0xFF1D4ED8)),
      ),
    );
    if (tooltip == null) return btn;
    return Tooltip(message: tooltip, child: btn);
  }
}
