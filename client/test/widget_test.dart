import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggy_pal/models/role.dart';
import 'package:piggy_pal/pages/home_page.dart';

const _testRoles = [
  Role(
    id: 'peppa',
    name: '佩奇',
    en: 'Peppa',
    image: 'assets/peppa.png',
    catchphrase: '嗨，我是佩奇～',
    sayEn: 'H-hi!',
    hello: '嗨，我是佩奇～',
  ),
];

void main() {
  setUp(() {
    // 预置已选宝宝，避免首页触发「首次进入自动选宝宝」导航
    SharedPreferences.setMockInitialValues({
      'child_id': 'test_child',
      'child_name': '测试宝宝',
    });
  });

  testWidgets('首页渲染标题、开始按钮与角色', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: HomePage(initialRoles: _testRoles)),
    );
    await tester.pump();

    expect(find.text('英语陪伴'), findsOneWidget);
    expect(find.textContaining('开始陪伴'), findsOneWidget);
    expect(find.text('佩奇'), findsOneWidget);
    expect(find.textContaining('说英文单词就能拿星星'), findsOneWidget);
  });
}
