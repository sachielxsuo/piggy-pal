import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

/// 最近 30 条对话的本地缓存。
///
/// 进入对话页先秒开本地记录（断网也能看到上次聊到哪），再和服务端对齐；
/// 只存消息 ID + 说话人 + 文本，不存 TTS 音频，避免 SharedPreferences 被撑大。
/// 消息 ID 用于上滑时向服务端分页拉更早的记录（before_id）。
class ChatHistoryStore {
  /// 本地保留的对话条数（约 20~30 条）。
  static const int keep = 30;

  static String _key(String childId, String roleId) =>
      'chat_history_${childId}_$roleId';

  Future<List<ChatMsg>> load({
    required String childId,
    required String roleId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(childId, roleId));
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map(
            (e) => ChatMsg(
              id: (e['id'] as num?)?.toInt() ?? 0,
              who: e['who'] == 'child' ? 'child' : 'ai',
              text: (e['text'] ?? '').toString(),
            ),
          )
          .where((m) => m.text.trim().isNotEmpty)
          .toList();
    } catch (_) {
      // 缓存损坏 / 版本不兼容：当作没有，等网络刷新
      return const [];
    }
  }

  Future<void> save({
    required String childId,
    required String roleId,
    required List<ChatMsg> messages,
  }) async {
    final tail = messages.length > keep
        ? messages.sublist(messages.length - keep)
        : messages;
    final data = tail
        .map((m) => {'id': m.id, 'who': m.who, 'text': m.text})
        .toList(growable: false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(childId, roleId), jsonEncode(data));
  }
}
