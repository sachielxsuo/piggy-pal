/// 服务端返回的最新客户端版本信息（GET /app/latest）。
class AppUpdate {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final int size;
  final String sha256;
  final String changelog;
  final bool force;

  /// 允许继续使用的最低 versionCode（0 = 不启用强制更新）。
  /// 低于它时客户端弹不可关闭的强制更新窗，只能更新或退出。
  final int minVersionCode;

  const AppUpdate({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.size,
    required this.sha256,
    required this.changelog,
    required this.force,
    this.minVersionCode = 0,
  });

  factory AppUpdate.fromJson(Map<String, dynamic> json) => AppUpdate(
    versionCode: (json['version_code'] as num?)?.toInt() ?? 0,
    versionName: (json['version_name'] ?? '').toString(),
    apkUrl: (json['apk_url'] ?? '').toString(),
    size: (json['size'] as num?)?.toInt() ?? 0,
    sha256: (json['sha256'] ?? '').toString(),
    changelog: (json['changelog'] ?? '').toString(),
    force: json['force'] == true,
    minVersionCode: (json['min_version_code'] as num?)?.toInt() ?? 0,
  );

  /// 当前版本是否低于最低可用版本。
  /// 当前版本号未知（0）时不做判断，避免读不到包信息就把人挡在门外。
  bool forcesUpdateFor(int currentVersionCode) =>
      minVersionCode > 0 &&
      currentVersionCode > 0 &&
      minVersionCode > currentVersionCode;

  /// 下载大小，家长能大致知道要等多久。
  String get sizeLabel {
    if (size <= 0) return '';
    final mb = size / (1024 * 1024);
    if (mb >= 1) return '${mb.toStringAsFixed(1)} MB';
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}
