# Android 发布检查清单（release 包）

> 背景：Flutter 的 **debug 包不做 R8 压缩，release 包会**。所以「debug 一切正常、release 一装就挂」是这类问题的典型表现——2026-10-25 的选宝宝页 / 星星页一直 loading 就是 R8 把 `shared_preferences` 的 JNI 方法签名改坏导致的。

每次发 release 包，按下面走一遍，5 分钟能挡掉 90% 的问题。

> 本文里的 `203.0.113.10` / `piggy.example.com` 都是**占位符**（真实地址不入库），
> 换成本机 `deploy.env` 里的 `PIGGYPAL_SERVER` / `PIGGYPAL_DOMAIN` 后再执行。

## 1. 打包（自动校验）

```bash
./build.sh
```

除了出包，脚本会解包检查 `classes.dex`：

- `SharedPreferencesApiRegistrar.getAll(...Lkotlin/coroutines/Continuation;)` 签名是否还在
- `kotlin/coroutines/intrinsics/CoroutineSingletons` 是否被裁掉

任一缺失会直接失败，并提示检查 `client/android/app/proguard-rules.pro`。这类「JNI 按名字找类/方法」的插件，R8 不会自动保护，必须在 proguard 规则里 keep。

> vivo / iQOO 真机实测：`adb install` 会弹系统安装确认，**必须人工勾选协议并点「继续安装」**，`Success` 只代表人工确认后安装完成；不点会一直等，最后超时。想无人值守，先在开发者选项打开「USB 安装」（部分机型还要关「监控 ADB 安装应用」）。

## 1.1 发布到线上（自动更新）

```bash
# 先改 client/pubspec.yaml：1.0.1+2 → 1.0.2+3（versionCode 必须递增）
./release_apk.sh "这次改了什么"
```

脚本会打包、上传 APK 到服务器 `data/releases/`、写 `latest.json`、清理旧包，并直接请求线上 `/app/latest` 验证。
已经装了旧版的手机下次启动会在「关于」入口显示红点（可点进「家长中心 → 关于」，或首页抽屉的「关于」）；点「检查更新」才真正开始下载安装，不会自己弹窗。

> 增量更新暂不做：差分包要按历史版本维护基线、端上合并二进制，签名 / ABI 不匹配就装不上；当前全量 20MB 更稳。

### 1.2 强制更新（最低版本号）

`latest.json` 里的 `min_version_code` 是「允许继续使用的最低 versionCode」。
低于它的客户端启动 / 收到心跳后会弹**不可关闭**的窗口（返回键、点外部都不行），
只能「立即更新」或「退出」，装完新版本才会消失。

```bash
./release_apk.sh "协议升级，必须更新" --min 19   # 低于 19 的强制更新
./release_apk.sh "..." --force                   # 等价于 --min 本次 versionCode
./release_apk.sh "..." --min 0                   # 解除强制更新
```

不传 `--min` / `--force` 时，脚本会沿用线上 `latest.json` 里已有的最低版本号，
发个普通版本不会顺手把强制更新关掉。

注意：

- 强制更新没有退路，发之前先确认这一版能装、能启动
- `min_version_code` 必须 `<=` 本次 `versionCode`；脚本会拒绝，服务端也会再夹一次
- 没网时不拦人：拿不到 `latest.json` 就不知道最低版本，宁可让宝宝先用着，也不能把 App 变砖
- 客户端只在 `versionCode > 0` 时判断，读不到包信息不会误伤

## 2. 真机冷启动走一遍首用路径

卸载旧版 → 装新包 → 冷启动：

- [ ] 首页角色能出来（`GET /roles`）
- [ ] 自动进入「选宝宝」不转圈（读 SharedPreferences + `GET /child`）
- [ ] 创建宝宝 → 保存成功（`POST /child`）
- [ ] 星星奖励页正常出数据（读 SharedPreferences + `GET /child/:id/stats`）
- [ ] 对话一轮：按住说话有波形、松开发送、有回复和 TTS
- [ ] 结束页星星结算正常

其中「选宝宝 / 星星页」专门用来覆盖本地缓存，这两页能开，SharedPreferences 就是好的。

## 3. 检查客户端异常

```bash
# 未捕获异常（含 PlatformException / NoSuchMethodError）
adb logcat -d | grep -E "E flutter|FATAL|Unhandled Exception"

# App 自己落的日志（release 也写）
adb shell cat /sdcard/Android/data/com.piggypal.piggy_pal/files/logs/*.log
```

日志文件里出现 `[E]` 或 `未处理的异步异常` 都要当问题查，不要只看界面有没有崩。

也可以在 **关于 → 运行日志** 点云上传，服务端 `/var/log/piggy-pal/client/` 应出现以日志起始时间命名的文件：

```bash
ssh root@203.0.113.10 'ls -lt /var/log/piggy-pal/client | head'
```

## 4. 确认请求真的到了服务端

```bash
ssh root@203.0.113.10 'tail -f /var/log/piggy-pal/server.log'
```

在手机上操作对应页面，看是否有对应的 `GET /child`、`GET /child/:id/stats`，以及状态码是否 200。**界面转圈时先看服务端有没有请求**——没有请求就是客户端问题，有请求再看服务端。

## 5. 工具链层面的兜底

- `.github/workflows/ci.yml`：每次 push 自动跑 `flutter analyze` / `flutter test` / `go vet` / `go test`，并打一次 release APK 跑第 1 步的 R8 校验
- 关键插件升级（`shared_preferences`、`record`、`permission_handler` 等）后，重点回归首次使用路径
- 涉及 JNI / 反射 / 序列化的插件，优先在 `proguard-rules.pro` 里补 keep，再用 `./build.sh` 验证
- 新增页面如果要读本地缓存 / 请求接口，务必把加载状态放在 `try/finally` 里，失败要落到「重试」而不是一直 loading
