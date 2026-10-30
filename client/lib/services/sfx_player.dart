import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// 本地音效：得星「叮」和达成小目标的庆祝音。
///
/// 声音是奖励闭环的一半——4-6 岁对即时声音反馈远比对数字敏感。
/// 音频是本地 WAV（assets/sfx/），不联网、不走 TTS，点一下就响。
/// 用独立的 player，避免和角色说话（TTS）互相打断。
class SfxPlayer {
  final AudioPlayer _star = AudioPlayer();
  final AudioPlayer _goal = AudioPlayer();
  bool _ready = false;

  /// 提前把两段音效装载进内存，第一次得星不会因为加载而延迟。
  Future<void> preload() async {
    if (_ready) return;
    _ready = true;
    try {
      await Future.wait([
        _star.setAsset('assets/sfx/star.wav'),
        _goal.setAsset('assets/sfx/goal.wav'),
      ]);
    } catch (_) {
      // 音效加载失败不影响对话，静默降级为无声
    }
  }

  Future<void> star() => _play(_star);

  Future<void> goal() => _play(_goal);

  Future<void> _play(AudioPlayer player) async {
    try {
      // 连续得星时从头重播，不排队
      await player.seek(Duration.zero);
      unawaited(player.play());
    } catch (_) {
      // 播放失败不影响主流程
    }
  }

  Future<void> dispose() async {
    try {
      await _star.dispose();
    } catch (_) {}
    try {
      await _goal.dispose();
    } catch (_) {}
  }
}
