import 'package:flutter_test/flutter_test.dart';
import 'package:piggy_pal/services/sse.dart';

void main() {
  group('SseParser', () {
    test('一次喂入多个事件', () {
      final p = SseParser();
      final out = p.feed(
        'event: asr\ndata: {"child_text":"apple"}\n\n'
        'event: reply\ndata: {"reply_text":"Good job!","stars":1}\n\n',
      );
      expect(out.length, 2);
      expect(out[0].event, 'asr');
      expect(out[0].data, '{"child_text":"apple"}');
      expect(out[1].event, 'reply');
    });

    test('事件被网络分片切开也能正确解析', () {
      final p = SseParser();
      expect(p.feed('event: asr\ndata: {"child_'), isEmpty);
      expect(p.feed('text":"apple"}\n'), isEmpty);
      final out = p.feed('\n');
      expect(out.length, 1);
      expect(out.single.event, 'asr');
      expect(out.single.data, '{"child_text":"apple"}');
    });

    test('data 里带冒号和换行不会被截断', () {
      final p = SseParser();
      final out = p.feed('event: reply\ndata: {"reply_text":"a: b"}\n\n');
      expect(out.single.data, '{"reply_text":"a: b"}');
    });

    test('CRLF 与注释行', () {
      final p = SseParser();
      final out = p.feed(': keep-alive\r\nevent: audio\r\ndata: {"index":0}\r\n\r\n');
      expect(out.length, 1);
      expect(out.single.event, 'audio');
      expect(out.single.data, '{"index":0}');
    });

    test('没有 data 的块被忽略', () {
      final p = SseParser();
      expect(p.feed('event: ping\n\n'), isEmpty);
    });
  });
}
