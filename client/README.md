# client（Flutter 客户端）

PiggyPal 客户端，Android/iOS（Android 首发）。

## 已实现

- **首页**：沉浸式场景（天空/太阳/云/草地）+ 整块 `PageView` swiper 切换角色（佩奇/乔治）+ 左侧抽屉（二级入口）
- **对话页**：沉浸头图 + 消息流 + 全宽「点击说话」+ 本地 mock 对话循环
- **角色数据**：`lib/data/mock_data.dart`（佩奇/乔治 + mock 对话流）
- **素材**：`assets/peppa.png`、`assets/george.png`

## 运行

```bash
flutter pub get
flutter run          # 需 Android 模拟器或真机
```

## 目录

```
lib/
├── main.dart              # 入口
├── pages/home_page.dart   # 首页
├── pages/chat_page.dart   # 对话页
├── models/role.dart       # 角色模型
└── data/mock_data.dart    # mock 数据
assets/                    # 佩奇/乔治素材
```
