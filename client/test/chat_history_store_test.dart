import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggy_pal/models/chat_message.dart';
import 'package:piggy_pal/services/chat_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('保存时只保留最近 30 条，按顺序读回', () async {
    final store = ChatHistoryStore();
    final messages = List.generate(
      35,
      (i) => ChatMsg(id: i + 1, who: i.isEven ? 'child' : 'ai', text: 'm$i'),
    );

    await store.save(childId: 'anan', roleId: 'peppa', messages: messages);
    final loaded = await store.load(childId: 'anan', roleId: 'peppa');

    expect(loaded.length, ChatHistoryStore.keep);
    expect(loaded.first.text, 'm5');
    expect(loaded.last.text, 'm34');
    expect(loaded.first.who, 'ai'); // 第 5 条是奇数 → ai
    expect(loaded.last.who, 'child'); // 第 34 条是偶数 → child
    // 消息 ID 也要一起缓存，上滑分页才知道从哪里往前拉
    expect(loaded.first.id, 6);
    expect(loaded.last.id, 35);
  });

  test('宝宝 / 角色互相隔离，没有记录返回空列表', () async {
    final store = ChatHistoryStore();
    await store.save(
      childId: 'anan',
      roleId: 'peppa',
      messages: const [ChatMsg(who: 'ai', text: 'hi')],
    );

    expect((await store.load(childId: 'anan', roleId: 'peppa')).length, 1);
    expect(await store.load(childId: 'anan', roleId: 'george'), isEmpty);
    expect(await store.load(childId: 'bob', roleId: 'peppa'), isEmpty);
  });

  test('缓存损坏时安全回退为空列表', () async {
    SharedPreferences.setMockInitialValues({
      'chat_history_anan_peppa': 'not-json',
    });
    final store = ChatHistoryStore();
    expect(await store.load(childId: 'anan', roleId: 'peppa'), isEmpty);
  });

  test('过滤空文本消息', () async {
    final store = ChatHistoryStore();
    await store.save(
      childId: 'anan',
      roleId: 'peppa',
      messages: const [
        ChatMsg(who: 'ai', text: 'hello'),
        ChatMsg(who: 'child', text: '   '),
        ChatMsg(who: 'child', text: 'hi'),
      ],
    );
    final loaded = await store.load(childId: 'anan', roleId: 'peppa');
    expect(loaded.map((m) => m.text), ['hello', 'hi']);
  });
}
