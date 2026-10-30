class Role {
  final String id;
  final String name;
  final String en;
  final String image;
  final String catchphrase;
  final String sayEn;
  final String hello;

  const Role({
    required this.id,
    required this.name,
    required this.en,
    required this.image,
    required this.catchphrase,
    required this.sayEn,
    required this.hello,
  });

  /// 从服务端 /roles 返回的条目构造；图片按约定取 `assets/{role_id}.png`。
  factory Role.fromJson(Map<String, dynamic> json) {
    final id = json['role_id'] as String? ?? '';
    return Role(
      id: id,
      name: json['name'] as String? ?? '',
      en: json['en'] as String? ?? '',
      image: 'assets/$id.png',
      catchphrase: json['catchphrase'] as String? ?? '',
      sayEn: json['say_en'] as String? ?? '',
      hello: json['hello'] as String? ?? '',
    );
  }
}
