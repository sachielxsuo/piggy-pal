/// 首页角色的自我介绍语音：先中文自我介绍，再英文口号。
/// 由服务端按角色音色合成，客户端按 role_id 缓存在内存里，切回同一个角色不重复请求。
class RoleGreeting {
  final String roleId;
  final String audioB64;
  final String format;

  const RoleGreeting({
    required this.roleId,
    required this.audioB64,
    this.format = 'mp3',
  });

  factory RoleGreeting.fromJson(Map<String, dynamic> json) {
    return RoleGreeting(
      roleId: json['role_id'] as String? ?? '',
      audioB64: json['audio_b64'] as String? ?? '',
      format: json['audio_format'] as String? ?? 'mp3',
    );
  }
}
