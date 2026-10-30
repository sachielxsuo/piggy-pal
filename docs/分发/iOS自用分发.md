# iOS 自用分发 Checklist

> 状态：v1.0（2026-10-20）
> 范围：把 PiggyPal 装到家人 iPhone 上的账号、签名、安装流程
> 前提：自用、非商用；走 **Ad Hoc 分发**，不上架 App Store（佩奇 IP 版权，上架必拒）
> 打包入口：`./build.sh -p ios`（`flutter build ipa --release`，当前环境未配 Xcode）

---

## 一、结论速览

| 问题 | 答案 |
|---|---|
| 要不要开发者账号？ | 要。免费 Apple ID 可用但**每 7 天重签**；推荐 **$99/年个人开发者账号** |
| 要不要签名？ | 要，iOS 所有安装都要签名 + Provisioning Profile |
| 装家人手机难吗？ | 不难：登记设备 UDID → 打 Ad Hoc 包 → 安装，App 有效期 1 年 |
| 上架 App Store？ | 走不通（佩奇 IP 版权），自用场景也不需要 |

---

## 二、账号类型与费用

| 账号 | 费用 | 证书有效期 | 设备数/年 | 适用 |
|---|---|---|---|---|
| 免费 Apple ID（Personal Team） | 0 | **7 天**（重签重装） | 10 台 | 偶尔演示 |
| **个人开发者**（Individual） | **$99/年** | 1 年 | 100 台 | ✅ **推荐** |
| 企业开发者（Enterprise） | $299/年 | 1 年 | 不限 | ❌ 需企业 DUNS 编号，个人用不了 |

> 金额以 Apple 当前定价为准，可能变动。

---

## 三、签名三件套（iOS 版）

| 文件 | 说明 |
|---|---|
| 证书 `.cer` | Development（开发）/ Distribution（分发） |
| Provisioning Profile | Development / **Ad Hoc** / App Store |
| 设备 UDID | Ad Hoc 与 Development 必须逐台登记 |

Xcode 的「Automatically manage signing」会自动处理证书与 Profile 的生成，只需在项目里选好 Team 和类型。

---

## 四、分发方式对比

| 方式 | 门槛 | 是否绑 UDID | 有效期 | 审核 | 适合 PiggyPal？ |
|---|---|---|---|---|---|
| 免费 Apple ID + Xcode 直连 | 免费 | 是 | 7 天 | 无 | 仅临时演示 |
| **Ad Hoc 分发** | $99/年 | 是 | 1 年 | 无 | ✅ **推荐** |
| TestFlight 内测 | $99/年 | 否（走邀请） | 单 build 90 天 | **有 Beta 审核** | ⚠️ IP 版权有风险 |
| App Store 上架 | $99/年 + 软著等 | 否 | 长期 | 正式审核 | ❌ IP 版权必拒 |

---

## 五、推荐路径：Ad Hoc 分发（分步）

> 前提：macOS + Xcode + CocoaPods 已装，工程能 `flutter build ios` 编译通过。
> 包名（Bundle ID）：`com.piggypal.piggyPal`

1. **购买个人开发者账号**
   - [ ] 注册 Apple ID（或用现有的）
   - [ ] 加入 Apple Developer Program，年费 $99，完成实名

2. **登记家人设备 UDID**
   - [ ] 每台 iPhone 连 Mac，Xcode → Window → Devices and Simulators 查看 UDID
   - [ ] 到开发者后台 `developer.apple.com` → Devices → 添加全部家人设备 UDID

3. **配置签名**
   - [ ] `client/ios/Runner.xcworkspace` 用 Xcode 打开
   - [ ] Signing & Capabilities：勾选 Automatically manage signing
   - [ ] Team 选你的个人账号，Bundle Identifier 保持 `com.piggypal.piggyPal`

4. **打包 Ad Hoc .ipa**
   - [ ] Xcode 菜单 Product → Archive（选真机 Generic iOS Device）
   - [ ] Organizer → Distribute App → 选 **Ad Hoc**
   - [ ] 勾选已登记的家人设备，导出 `.ipa`
   - 或命令行：`flutter build ipa --release`（需先配好签名）

5. **安装到家人手机**
   - [ ] 方式一：Apple Configurator 2（Mac 免费工具）拖入 `.ipa`
   - [ ] 方式二：隔空投送（AirDrop）`.ipa` 到手机，手机上点安装
   - [ ] 方式三：爱思助手 / 第三方工具侧载
   - [ ] 首次启动在「设置 → 通用 → VPN 与设备管理」信任该开发者证书

6. **验证**
   - [ ] 麦克风权限弹窗正常（`NSMicrophoneUsageDescription` 已配置）
   - [ ] 录音 → 后端 ASR → TTS 播放全链路通
   - [ ] App 运行正常（Ad Hoc 包有效期 1 年，到期前重新打包安装）

---

## 六、为什么不用 TestFlight

TestFlight 需要把 build 上传 App Store Connect 并过 **Beta App Review**。虽然比正式审核宽松，但 PiggyPal 含佩奇 IP，仍可能因版权 / 名称问题被拒。Ad Hoc 完全绕开 Apple 审核，自用最稳。

---

## 七、针对 PiggyPal 的注意事项

1. **IP 版权**：佩奇是 eOne/Hasbro 版权，App Store / TestFlight 都有审核风险，**只走 Ad Hoc**。
2. **后端 HTTPS**：iOS ATS 默认要求 HTTPS，`https://piggy.example.com` 已满足，无需额外配置。
3. **打包脚本**：`build.sh -p ios` 已预留 `flutter build ipa --release`，环境配好后即可用；如需 Ad Hoc 导出，仍建议走 Xcode Archive（可选签名/设备更直观）。
4. **音频**：iOS 端 `record` / `just_audio` 有官方原生支持（不像鸿蒙需换适配版），录音 16kHz WAV、mp3 播放基本开箱可用，风险低于鸿蒙。
5. **免费 vs 付费**：如果只是给自家孩子偶发用，免费 Apple ID 也能跑，但**每 7 天要连电脑重签重装**，长期用强烈建议直接 $99/年。

---

## 八、需核实项（随 Apple 政策变动）

- [ ] 个人开发者年费当前金额
- [ ] 免费账号设备数 / 证书有效期是否有调整
- [ ] Ad Hoc 包在最新 iOS 上的安装提示流程
