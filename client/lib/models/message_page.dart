import 'chat_message.dart';

/// 一页历史对话（正序：最早在前）。
class MessagePage {
  final List<ChatMsg> messages;

  /// 是否还有更早的消息（上滑可继续加载）。
  final bool hasMore;

  const MessagePage({required this.messages, required this.hasMore});

  static const MessagePage empty = MessagePage(messages: [], hasMore: false);
}
