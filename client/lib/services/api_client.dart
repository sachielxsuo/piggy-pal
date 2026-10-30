import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/env.dart';
import '../models/bedtime_story.dart';
import '../models/chat_message.dart';
import '../models/child.dart';
import '../models/child_stats.dart';
import '../models/daily_greeting.dart';
import '../models/learning_plan.dart';
import '../models/message_page.dart';
import '../models/role.dart';
import '../models/role_greeting.dart';
import '../models/sticker.dart';
import '../models/word_entry.dart';
import 'client_identity.dart';
import 'logger.dart';
import 'sse.dart';

/// 后端 HTTP 客户端。
class ApiClient {
  late final Dio _dio;

  ApiClient() {
    _dio = Dio(
      BaseOptions(
        baseUrl: Env.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        headers: {if (Env.apiToken.isNotEmpty) 'X-API-Token': Env.apiToken},
      ),
    );

    // 每个请求都带 client_id：服务端访问日志据此把每行日志对上具体设备。
    // 不改接口签名，避免每个方法都手动拼一遍。
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          try {
            options.headers['X-Client-Id'] = await ClientIdentity.id();
          } catch (e) {
            // 拿不到 client_id 不影响业务，只是服务端日志少一列
            AppLog.w('api', '读取 client_id 失败: $e');
          }
          handler.next(options);
        },
      ),
    );

    // 记录请求/响应/错误，便于定位（不打印 body，避免大段 base64 刷屏）
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          AppLog.i('api', '→ ${options.method} ${options.uri}');
          handler.next(options);
        },
        onResponse: (resp, handler) {
          AppLog.i('api', '← ${resp.statusCode} ${resp.requestOptions.uri}');
          handler.next(resp);
        },
        onError: (e, handler) {
          AppLog.e('api', '✗ ${e.requestOptions.uri} :: ${e.message}');
          handler.next(e);
        },
      ),
    );
  }

  /// 角色列表（服务端 /roles 返回，图片按 role_id 约定取本地 asset）。
  Future<List<Role>> fetchRoles() async {
    final resp = await _dio.get('/roles');
    final list = (resp.data['roles'] as List?) ?? const [];
    return list.map((e) => Role.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 角色自我介绍语音（首页自动播放：中文自我介绍 + 英文口号）。
  /// 服务端 TTS 未配置时返回 503，调用方应静默跳过。
  Future<RoleGreeting> fetchRoleGreeting(String roleId) async {
    final resp = await _dio.get('/roles/$roleId/greet');
    return RoleGreeting.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 倒计时语音提醒：kind 只支持 `2min` / `30s`（文案由服务端固定）。
  Future<Map<String, dynamic>> fetchTimeWarning(
    String roleId,
    String kind,
  ) async {
    final resp = await _dio.get(
      '/roles/$roleId/time-warning',
      queryParameters: {'kind': kind},
    );
    return (resp.data as Map).cast<String, dynamic>();
  }

  /// 某宝宝与某角色的历史对话（正序），进入对话页时回显。
  Future<MessagePage> fetchMessages({
    required String childId,
    required String roleId,
    int limit = 50,
    int beforeId = 0,
  }) async {
    final resp = await _dio.get(
      '/child/$childId/messages',
      queryParameters: {
        'role_id': roleId,
        'limit': limit,
        if (beforeId > 0) 'before_id': beforeId,
      },
    );
    final data = (resp.data as Map).cast<String, dynamic>();
    final raw = (data['messages'] as List?) ?? const [];
    final messages = raw
        .map(
          (e) => ChatMsg(
            id: (e['id'] as num?)?.toInt() ?? 0,
            who: (e['speaker'] ?? 'ai') == 'child' ? 'child' : 'ai',
            text: (e['content'] ?? '').toString(),
          ),
        )
        .where((m) => m.text.trim().isNotEmpty)
        .toList();
    return MessagePage(messages: messages, hasMore: data['has_more'] == true);
  }

  /// 重播历史 AI 消息：历史接口不返回音频，点喇叭时再按消息 ID 取。
  /// 服务端 TTS 未配置时返回 503，调用方静默跳过。
  /// slow=true 让服务端用 0.75 倍语速重新合成（跟读时听连读更清楚）。
  Future<String> fetchMessageAudio({
    required String childId,
    required int messageId,
    bool slow = false,
  }) async {
    final resp = await _dio.get(
      '/child/$childId/messages/$messageId/audio',
      queryParameters: slow ? const {'slow': '1'} : null,
    );
    return (resp.data['audio_b64'] ?? '').toString();
  }

  /// 今天的开场话题：每天首次进入角色对话页时由服务端生成，当天复用。
  Future<DailyGreeting> fetchDailyGreeting({
    required String childId,
    required String roleId,
  }) async {
    final resp = await _dio.get('/child/$childId/daily-greeting/$roleId');
    return DailyGreeting.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 宝宝列表。
  Future<List<Child>> fetchChildren() async {
    final resp = await _dio.get('/child');
    final list = (resp.data['children'] as List?) ?? const [];
    return list.map((e) => Child.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 创建/更新宝宝档案。
  Future<void> upsertChild(Child child) async {
    await _dio.post('/child', data: child.toJson());
  }

  /// 对话：text 与 audioB64 二选一。
  Future<Map<String, dynamic>> chat({
    required String childId,
    required String roleId,
    String? text,
    String? audioB64,
    String? sessionId,
    String voiceFormat = 'wav',
  }) async {
    final resp = await _dio.post(
      '/child/$childId/chat',
      data: {
        'role_id': roleId,
        'text': text ?? '',
        'audio_b64': audioB64 ?? '',
        'voice_format': voiceFormat,
        'session_id': sessionId ?? '',
      },
    );
    return (resp.data as Map).cast<String, dynamic>();
  }

  /// 流式对话：服务端分阶段推 asr / reply / audio 事件。
  ///
  /// - `asr`：宝宝说的话刚识别出来，客户端可以立刻上屏
  /// - `reply`：佩奇的回复文本 + 星星（语音可能还没好）
  /// - `audio`：一句 TTS 音频，可能有多条，按到达顺序播放
  ///
  /// 服务端在流里报错时会抛异常，由页面决定是否展示重试。
  Future<void> chatStream({
    required String childId,
    required String roleId,
    String? text,
    String? audioB64,
    required String sessionId,
    String voiceFormat = 'wav',
    required void Function(String event, Map<String, dynamic> data) onEvent,
  }) async {
    final resp = await _dio.post<ResponseBody>(
      '/child/$childId/chat/stream',
      data: {
        'role_id': roleId,
        if (text != null && text.trim().isNotEmpty) 'text': text.trim(),
        if (audioB64 != null && audioB64.isNotEmpty) 'audio_b64': audioB64,
        'voice_format': voiceFormat,
        'session_id': sessionId,
      },
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 120),
        headers: {'Accept': 'text/event-stream'},
      ),
    );
    final body = resp.data;
    if (body == null) {
      throw Exception('流式响应为空');
    }
    final parser = SseParser();
    // 用流式 utf8 decoder：多字节汉字被网络切在两个分片时不会乱码
    await for (final chunk in utf8.decoder.bind(body.stream)) {
      for (final ev in parser.feed(chunk)) {
        final data = _decodeEventData(ev.data);
        if (ev.event == 'error') {
          throw Exception((data['error'] ?? '对话失败').toString());
        }
        onEvent(ev.event, data);
      }
    }
  }

  Map<String, dynamic> _decodeEventData(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } catch (e) {
      AppLog.w('api', '解析 SSE 事件失败: $e');
    }
    return const {};
  }

  /// 宝宝统计：今日 / 最近 7 天 / 累计 / 连续天数。
  Future<ChildStats> fetchStats(String childId) async {
    final resp = await _dio.get('/child/$childId/stats');
    return ChildStats.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 本周学习计划（首次调用会触发生成，周一自动换新）。
  Future<LearningPlan> fetchLearningPlan(String childId) async {
    final resp = await _dio.get('/child/$childId/learning-plan');
    return LearningPlan.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 贴纸墙：按累计星星解锁，不消费星星。
  Future<StickerBoard> fetchStickers(String childId) async {
    final resp = await _dio.get('/child/$childId/stickers');
    return StickerBoard.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 今天的睡前故事（当天生成一次；[slow] 用 0.75 倍语速合成）。
  Future<BedtimeStory> fetchBedtimeStory({
    required String childId,
    required String roleId,
    bool slow = false,
  }) async {
    final resp = await _dio.get(
      '/child/$childId/bedtime-story/$roleId',
      queryParameters: slow ? const {'slow': '1'} : null,
      options: Options(receiveTimeout: const Duration(seconds: 90)),
    );
    return BedtimeStory.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 点词查词典：音标、释义、例句、真人发音（正常 / 慢读）。
  /// [msgId] 传点击所在消息，服务端会顺手返回原句做语境例句。
  Future<WordEntry> fetchWordEntry({
    required String childId,
    required String word,
    String? roleId,
    int? msgId,
  }) async {
    final resp = await _dio.get(
      '/child/$childId/dict/${Uri.encodeComponent(word)}',
      queryParameters: {
        if (roleId != null && roleId.isNotEmpty) 'role_id': roleId,
        if (msgId != null && msgId > 0) 'msg_id': msgId,
      },
    );
    return WordEntry.fromJson((resp.data as Map).cast<String, dynamic>());
  }

  /// 防抖同步本次会话星星（绝对值快照，服务端只增不减）。
  Future<int> syncSession(
    String childId, {
    required String sessionId,
    required int stars,
  }) async {
    final resp = await _dio.post(
      '/child/$childId/session/sync',
      data: {'session_id': sessionId, 'stars': stars},
    );
    return (resp.data['session_stars'] as num?)?.toInt() ?? stars;
  }

  /// 结束页：道别 + 星星结算 + 预告明日（含角色音色 TTS，可能为空）。
  Future<Map<String, dynamic>> goodbye({
    required String childId,
    required String roleId,
    required int stars,
    String? sessionId,
  }) async {
    final resp = await _dio.post(
      '/child/$childId/bye',
      data: {'role_id': roleId, 'stars': stars, 'session_id': sessionId ?? ''},
    );
    return (resp.data as Map).cast<String, dynamic>();
  }

  /// 校验家长 PIN，返回是否通过。
  Future<bool> verifyPin(String pin) async {
    final resp = await _dio.post('/parent/verify', data: {'pin': pin});
    return resp.data['ok'] == true;
  }

  /// 设置家长 PIN。
  Future<void> setPin(String pin) async {
    await _dio.post('/parent/pin', data: {'pin': pin});
  }

  /// 上传 App 运行日志（服务端按 `client/` 目录单独保存，不与 server.log 混放）。
  /// 返回服务端实际保存的文件名。
  Future<String> uploadClientLog({
    required String filename,
    required String content,
  }) async {
    // 带上 client_id：服务端按设备分目录保存，多台手机的日志不会混在一起
    final clientId = await ClientIdentity.id();
    final resp = await _dio.post(
      '/client-logs',
      data: {'filename': filename, 'content': content, 'client_id': clientId},
    );
    return (resp.data['filename'] as String?) ?? filename;
  }

  /// 30 秒一次的心跳：上报本次运行累计时长，顺便领取服务端下发的指令，
  /// 以及「有新版本」通知（`app_update`）。返回整个响应体。
  Future<Map<String, dynamic>> heartbeat(Map<String, dynamic> body) async {
    final resp = await _dio.post(
      '/client/heartbeat',
      data: body,
      options: Options(
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 10),
      ),
    );
    final data = resp.data;
    if (data is Map) return data.cast<String, dynamic>();
    return const {};
  }

  /// 指令执行回执（成功 / 失败都回，服务端据此停止重发）。
  Future<void> ackCommand(
    int id, {
    required bool ok,
    required String result,
  }) async {
    final clientId = await ClientIdentity.id();
    await _dio.post(
      '/client/commands/$id/ack',
      data: {'client_id': clientId, 'ok': ok, 'result': result},
    );
  }
}
