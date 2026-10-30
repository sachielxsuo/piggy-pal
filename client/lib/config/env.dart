/// 后端地址。
///
/// 真实域名不写进仓库：打包时由 `build.sh` / `release_apk.sh` 从根目录
/// 的 `deploy.env` 读出 `PIGGYPAL_DOMAIN`，再以
/// `--dart-define=API_BASE_URL=https://你的域名` 注入。
/// 这里的默认值只是占位符，忘记注入时会连不上（一眼就能发现，不会误连别人的服务器）。
///
/// 开发调试：本机启动 whistle，配一条规则把该域名转发到本地 18080，
/// 手机走 whistle 代理即可，无需改动此处。
class Env {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://piggy.example.com',
  );

  /// 开发调试用：whistle 代理地址（真机 = 电脑局域网 IP:8017）。
  /// 仅 debug 模式生效；留空则不走代理（release 生产直连域名）。
  /// 例：flutter run --dart-define=WHISTLE_PROXY=192.168.1.100:8017
  static const String whistleProxy =
      String.fromEnvironment('WHISTLE_PROXY', defaultValue: '');

  /// 全站共享访问令牌（与服务端 API_TOKEN 一致，请求头 X-API-Token）。
  /// run.sh / build.sh 会自动从 server/.env 读取并注入。
  /// 手动运行：flutter run --dart-define=API_TOKEN=xxx
  static const String apiToken =
      String.fromEnvironment('API_TOKEN', defaultValue: '');
}
