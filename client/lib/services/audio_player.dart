import 'dart:convert';
import 'dart:io';

import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

/// 播放封装：把 TTS 返回的 base64 音频落临时文件后播放。
class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer();

  Future<void> playBase64(String base64, {String format = 'mp3'}) async {
    final bytes = base64Decode(base64);
    final dir = await getTemporaryDirectory();
    await _cleanupOldFiles(dir);
    final file = File(
      '${dir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.$format',
    );
    await file.writeAsBytes(bytes);
    await _player.setFilePath(file.path);
    await _player.play();
  }

  /// 宝宝开始说话时先停掉 TTS，避免麦克风把佩奇的声音录进去。
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // 没在播放时 stop 也可能抛错，忽略即可
    }
  }

  /// 清理一小时前的 TTS 临时文件，避免长期使用把缓存目录撑大。
  Future<void> _cleanupOldFiles(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('tts_')) continue;
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {
          // 文件正被播放或已删除，跳过
        }
      }
    } catch (_) {
      // 清理失败不影响播放
    }
  }

  void dispose() => _player.dispose();
}
