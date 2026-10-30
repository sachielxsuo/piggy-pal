/// 一个单词的词典结果。
class WordSentence {
  final String en;
  final String? zh;

  const WordSentence({required this.en, this.zh});

  factory WordSentence.fromJson(Map<String, dynamic> json) {
    return WordSentence(
      en: (json['en'] ?? '').toString(),
      zh: (json['zh'] ?? '').toString().isEmpty
          ? null
          : (json['zh'] ?? '').toString(),
    );
  }
}

/// 点词查词的服务端返回，字段与 `GET /child/:id/dict/:word` 对齐。
class WordEntry {
  final String word;

  /// 原形（cats → cat），点复数 / 过去式时用得上。
  final String lemma;
  final String phonetic;
  final List<String> senses;

  /// 词典自带例句。
  final WordSentence? example;

  /// 点击所在的原句，比通用例句更有语境。
  final WordSentence? context;

  final String? audioB64;
  final String? audioSlowB64;

  /// human = 真人录音，tts = 合成音。
  final String? audioSource;
  final String? audioCredit;

  /// kid / basic / enriched
  final String level;
  final bool found;

  const WordEntry({
    required this.word,
    required this.lemma,
    required this.phonetic,
    required this.senses,
    required this.level,
    required this.found,
    this.example,
    this.context,
    this.audioB64,
    this.audioSlowB64,
    this.audioSource,
    this.audioCredit,
  });

  bool get hasAudio => (audioB64 ?? '').isNotEmpty;
  bool get isInflected => lemma.isNotEmpty && lemma != word.toLowerCase();

  factory WordEntry.fromJson(Map<String, dynamic> json) {
    final senses = (json['senses'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList() ??
        const <String>[];
    WordSentence? sentence(Object? raw) {
      if (raw is! Map) return null;
      final m = raw.cast<String, dynamic>();
      final en = (m['en'] ?? '').toString();
      if (en.isEmpty) return null;
      return WordSentence.fromJson(m);
    }

    String? str(Object? v) {
      final s = (v ?? '').toString();
      return s.isEmpty ? null : s;
    }

    return WordEntry(
      word: (json['word'] ?? '').toString(),
      lemma: (json['lemma'] ?? '').toString(),
      phonetic: (json['phonetic_us'] ?? '').toString(),
      senses: senses,
      example: sentence(json['example']),
      context: sentence(json['context']),
      audioB64: str(json['audio_b64']),
      audioSlowB64: str(json['audio_slow_b64']),
      audioSource: str(json['audio_source']),
      audioCredit: str(json['audio_credit']),
      level: (json['level'] ?? '').toString(),
      found: json['found'] == true,
    );
  }

  /// 只留文本字段，用于内存缓存时裁掉大段 base64。
  WordEntry withoutAudio() {
    return WordEntry(
      word: word,
      lemma: lemma,
      phonetic: phonetic,
      senses: senses,
      example: example,
      context: context,
      audioSource: audioSource,
      audioCredit: audioCredit,
      level: level,
      found: found,
    );
  }
}
