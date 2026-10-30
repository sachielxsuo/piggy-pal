import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 录音封装：按住说话 → 松开得到音频文件路径（AAC/m4a）。
class AudioRecorderService {
  final AudioRecorder _recorder = AudioRecorder();

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    await _cleanupOldFiles(dir);
    final path = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';
    // 16kHz 单声道 WAV：腾讯云一句话识别 16k 引擎的标准输入，避免采样率不匹配识别为空
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
  }

  /// 停止录音，返回音频文件路径（未录制则返回 null）。
  Future<String?> stop() => _recorder.stop();

  /// 实时音量（0~1），用于按住说话时的波形反馈。
  /// record 返回的是 dBFS（约 -160~0），把 -50~-10 映射到 0~1 更贴近人声。
  Stream<double> amplitudeLevels() {
    return _recorder.onAmplitudeChanged(const Duration(milliseconds: 100)).map((
      a,
    ) {
      final db = a.current.isFinite ? a.current : -160.0;
      return ((db + 50) / 40).clamp(0.0, 1.0).toDouble();
    });
  }

  /// 清理一小时前的录音临时文件，避免反复说话把缓存目录撑大。
  Future<void> _cleanupOldFiles(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(hours: 1));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (!name.startsWith('rec_')) continue;
        try {
          if ((await entity.stat()).modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {
          // 文件可能正在使用，跳过
        }
      }
    } catch (_) {
      // 清理失败不影响录音
    }
  }
}
