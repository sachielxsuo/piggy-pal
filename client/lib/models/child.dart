/// 宝宝档案（对应后端 child 表）。
class Child {
  final String childId;
  final String familyId;
  final String name;
  final String enName;
  final int age;
  final String gender;
  final String preferences;
  final String avatar;

  const Child({
    required this.childId,
    this.familyId = 'default',
    required this.name,
    this.enName = '',
    this.age = 0,
    this.gender = '',
    this.preferences = '',
    this.avatar = '',
  });

  factory Child.fromJson(Map<String, dynamic> json) => Child(
    childId: json['child_id'] ?? '',
    familyId: json['family_id'] ?? 'default',
    name: json['name'] ?? '',
    enName: json['en_name'] ?? '',
    age: json['age'] ?? 0,
    gender: json['gender'] ?? '',
    preferences: json['preferences'] ?? '',
    avatar: json['avatar'] ?? '',
  );

  Map<String, dynamic> toJson() => {
    'child_id': childId,
    'family_id': familyId,
    'name': name,
    'en_name': enName,
    'age': age,
    'gender': gender,
    'preferences': preferences,
    'avatar': avatar,
  };

  /// 开发者模式下的测试宝宝：family_id=dev 或 child_id 以 dev_ 开头。
  /// 未开启开发者模式时，客户端会把这类档案隐藏起来。
  bool get isDevChild => familyId == 'dev' || childId.startsWith('dev_');
}
