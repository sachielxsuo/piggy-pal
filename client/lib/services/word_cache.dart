import '../models/word_entry.dart';

/// 查词结果的内存缓存（LRU，按插入顺序淘汰）。
///
/// 连音频一起缓存：单条约 20KB，40 条上限不到 1MB，换来再次点同一个词零等待。
class WordCache {
  static const int _max = 40;
  static final Map<String, WordEntry> _entries = {};

  static String _key(String childId, String word) =>
      '$childId|${word.toLowerCase()}';

  static WordEntry? get(String childId, String word) {
    final key = _key(childId, word);
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit; // 命中后挪到队尾，保持 LRU
    return hit;
  }

  static void put(String childId, WordEntry entry) {
    final key = _key(childId, entry.word);
    _entries.remove(key);
    _entries[key] = entry;
    while (_entries.length > _max) {
      _entries.remove(_entries.keys.first);
    }
  }

  static void clear() => _entries.clear();
}
