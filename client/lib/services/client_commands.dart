import '../services/api_client.dart';
import 'logger.dart';

/// 执行服务端通过心跳下发的指令。
///
/// 目前只有一条：`upload_logs` —— 把客户端最近 24 小时的运行日志传到服务器，
/// 不用连电脑、不用 ADB 就能取现场。新增指令时在服务端 `allowedCommandTypes`
/// 登记，并在这里加一个 case。
class ClientCommands {
  static final ApiClient _api = ApiClient();

  static Future<void> run(List<Map<String, dynamic>> commands) async {
    for (final cmd in commands) {
      final id = (cmd['id'] as num?)?.toInt() ?? 0;
      if (id <= 0) continue;
      final type = (cmd['type'] ?? '').toString();

      var ok = false;
      var result = '';
      try {
        switch (type) {
          case 'upload_logs':
            result = await _uploadLogs();
            ok = true;
          default:
            result = '不支持的指令: $type';
        }
      } catch (e) {
        result = '执行失败: $e';
        AppLog.w('cmd', '指令 $type($id) 执行失败: $e');
      }

      // 成败都回执，否则服务端 10 分钟后会重发
      try {
        await _api.ackCommand(id, ok: ok, result: result);
        AppLog.i('cmd', '指令 $type($id) 已回执 ok=$ok result=$result');
      } catch (e) {
        AppLog.w('cmd', '指令 $type($id) 回执失败（服务端会重发）: $e');
      }
    }
  }

  /// 提取日志：最近 24 小时（比「关于」页手动上传的 2 小时更全）。
  static Future<String> _uploadLogs() async {
    final excerpt = await AppLog.excerpt(window: const Duration(hours: 24));
    if (excerpt.isEmpty) return '最近 24 小时没有日志';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final name = 'cmd-$stamp-${excerpt.fileName}';
    final saved = await _api.uploadClientLog(
      filename: name,
      content: excerpt.text,
    );
    return '已上传 $saved（${excerpt.lineCount} 行）';
  }
}
