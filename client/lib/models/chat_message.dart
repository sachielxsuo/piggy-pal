/// 一条对话消息（客户端展示用）。
class ChatMsg {
  /// 服务端消息 ID（本地缓存 / 上滑加载更早消息时用于分页，0 表示未知）。
  final int id;
  final String who; // 'child' / 'ai'
  final String text;
  final String? audioB64; // ai 消息的 TTS 音频（可能为空）

  const ChatMsg({
    this.id = 0,
    required this.who,
    required this.text,
    this.audioB64,
  });

  /// 补上语音（重播历史消息时按需从服务端取）后的副本。
  ChatMsg copyWith({String? audioB64}) => ChatMsg(
    id: id,
    who: who,
    text: text,
    audioB64: audioB64 ?? this.audioB64,
  );
}
