# PiggyPal（小猪玩伴）

3-6 岁宝宝英语陪伴 APP（**自用、非商用**），AI 虚拟玩伴（小猪佩奇 IP）。

自由式英语对话，全正向鼓励，每日陪伴流程（问候 → 轻互动 → 星星激励 → 道别 → 预告）。

## 技术栈

- **客户端**：Flutter（Android 首发，预留 iOS）
- **后端**：Go + Gin + modernc.org/sqlite
- **AI**：腾讯云（一句话识别 ASR / TTS）+ DeepSeek（大模型）

## 目录结构

```
piggy-pal/
├── client/    # Flutter 客户端（M3 阶段）
├── server/    # Go 后端
│   ├── cmd/server/        # 启动入口
│   ├── internal/          # config/http/service/store/model
│   └── config/            # roles.yaml / prompts.yaml / guard.yaml
├── docs/      # 设计文档（PRD、数据隔离方案、技术选型）
├── demo/      # HTML 交互原型
├── deploy.env.example  # 部署配置模板（复制成 deploy.env，真实值不入库）
└── README.md
```

## 快速开始

```bash
cd server
cp .env.example .env            # 填入腾讯云 CAM 密钥 + DeepSeek API Key + API_TOKEN
cd ..
cp deploy.env.example deploy.env  # 填入自己的服务器 IP 和域名
```

> `deploy.env` 只在本地存在，已被 `.gitignore` 忽略；仓库里所有文档一律用占位符
> `203.0.113.10` / `piggy.example.com`。发版脚本会自动读取 `deploy.env`，
> 所以文档里的命令要换成你自己的地址才能直接跑。
> 每个文件填什么的完整说明见 [配置引导](docs/配置引导.md)。
>
> 角色形象（`client/assets/*.png`）版权归他人，不在仓库里。缺图不影响运行，
> 客户端会显示「角色名首字 + 纯色圆」的占位头像；想要真图自己放进去，
> 文件名按 `role_id` 命名，见 [配置引导 · 角色形象](docs/配置引导.md#6-角色形象本地自备不进仓库)。

## 访问令牌（API_TOKEN）

服务端在配置了 `API_TOKEN` 后，除 `/healthz` 外所有接口都要求请求头 `X-API-Token`（也兼容 `Authorization: Bearer`）。

- 生成：`openssl rand -hex 24`，写进 `server/.env`
- 留空 = 关闭校验，仅限本地开发；公网部署务必设置
- 客户端由 `run.sh` / `build.sh` 自动从 `server/.env` 读取并注入（`--dart-define=API_TOKEN=...`）
- 后端地址同样在打包时注入（`--dart-define=API_BASE_URL=...`，取自 `deploy.env` 的 `PIGGYPAL_DOMAIN`），
  仓库里不写死任何真实域名
- **换 token 或换域名后需要重新打包客户端**

## 常用命令（封装脚本）

```bash
./server.sh          # 启动后端（:18080，Ctrl+C 停止）
./server.sh stop     # 停止后端
./run.sh             # 本地 debug 真机调试（自动抓局域网 IP，走 whistle）
./build.sh           # 线上打包 Android release APK（arm64 单架构）
./build.sh -p ios    # 打包 iOS（待配 Xcode + 开发者账号）
./release_apk.sh "更新说明"   # 打包 + 上传 APK + 写版本信息（客户端自动更新用）
./scripts/backup-secrets.sh   # 把 .env / keystore / 部署配置打成包（放 NAS）
```

> 发版前先把 `client/pubspec.yaml` 的 `version` 加一（如 `1.0.1+2` → `1.0.2+3`）；
> `+` 后面的 versionCode 必须比线上大，手机端才会提示更新。

> 真机调试依赖 whistle：配规则 `piggy.example.com http://127.0.0.1:18080`，详见 `run.sh` 注释。

## 文档

- [配置引导](docs/配置引导.md)：新机器要配哪些文件、每个字段填什么
- [密钥与恢复](docs/密钥与恢复.md)：密钥放哪、丢了怎么办、恢复演练
- [产品需求 PRD](docs/英语陪伴APP-PRD.md)
- [用户体系与数据隔离方案](docs/用户体系与数据隔离方案.md)
- [技术选型与方案设计](docs/技术选型与方案设计.md)
- [故障排查（日志优先）](docs/故障排查.md)
- [运维巡检与告警](docs/运维巡检.md)
- [Android 发布检查清单](docs/Android发布检查清单.md)
- 客户端分发（自用、不上架）
  - [鸿蒙自用分发](docs/分发/鸿蒙自用分发.md)
  - [iOS 自用分发](docs/分发/iOS自用分发.md)

## 许可

代码以 [MIT](LICENSE) 协议开源。

仓库里的第三方内容各有各的许可，**不适用** MIT：

| 内容 | 来源 | 许可 |
|---|---|---|
| 词典底库 `dict_base` | [ECDICT](https://github.com/skywind3000/ECDICT) | MIT |
| 单词发音 mp3 | Wikimedia Commons | CC BY-SA 3.0，逐文件出处与作者见 `server/internal/dict/data/audio/credits.json` |
| 角色形象 | 不在仓库里，本地自备 | 版权归各自权利人，见 [配置引导 · 角色形象](docs/配置引导.md#6-角色形象本地自备不进仓库) |

如果要拿去商用或公开发布，请自行替换角色形象，并遵守音频的 CC BY-SA 署名要求。
