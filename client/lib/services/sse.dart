/// 一条 SSE 事件：`event: reply` + `data: {...}`。
class SseEvent {
  final String event;
  final String data;

  const SseEvent(this.event, this.data);
}

/// 增量 SSE 解析器。
///
/// 服务端按 `event: <name>\ndata: <json>\n\n` 推送，网络分片可能把一行甚至
/// 一个多字节字符切开，所以这里只负责「攒够一个完整事件就吐出来」，
/// 字符解码交给调用方的 utf8 流式 decoder。
class SseParser {
  String _buf = '';

  /// 喂入一段文本，返回其中已经完整的事件（可能为空）。
  List<SseEvent> feed(String chunk) {
    _buf += chunk;
    // 统一成 \n 分隔：服务端用 \n，但代理 / 调试工具可能给 \r\n。
    // 每次对整段 buffer 归一化，避免 \r 与 \n 被切在两个分片里。
    if (_buf.contains('\r')) _buf = _buf.replaceAll('\r\n', '\n');
    final out = <SseEvent>[];
    while (true) {
      final i = _buf.indexOf('\n\n');
      if (i < 0) break;
      final block = _buf.substring(0, i);
      _buf = _buf.substring(i + 2);
      final ev = _parseBlock(block);
      if (ev != null) out.add(ev);
    }
    return out;
  }

  SseEvent? _parseBlock(String block) {
    var event = 'message';
    final data = StringBuffer();
    for (var line in block.split('\n')) {
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      // 空行 / 注释行（服务端心跳可能用 `:` 开头）
      if (line.isEmpty || line.startsWith(':')) continue;
      final idx = line.indexOf(':');
      final field = idx < 0 ? line : line.substring(0, idx);
      var value = idx < 0 ? '' : line.substring(idx + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        event = value;
      } else if (field == 'data') {
        if (data.isNotEmpty) data.write('\n');
        data.write(value);
      }
    }
    if (data.isEmpty) return null;
    return SseEvent(event, data.toString());
  }
}
