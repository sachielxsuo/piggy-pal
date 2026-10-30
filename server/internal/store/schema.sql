-- SQLite 运行时数据（规则/角色在 yaml 配置文件里，不在库）
CREATE TABLE IF NOT EXISTS child (
  child_id     TEXT PRIMARY KEY,
  family_id    TEXT,
  name         TEXT NOT NULL,
  en_name      TEXT,
  age          INTEGER,
  gender       TEXT,
  preferences  TEXT,
  avatar       TEXT,
  created_at   TEXT
);

CREATE TABLE IF NOT EXISTS chat_message (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  child_id   TEXT NOT NULL,
  role_id    TEXT NOT NULL,
  speaker    TEXT NOT NULL,
  content    TEXT,
  created_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_chat ON chat_message(child_id, role_id, created_at);

CREATE TABLE IF NOT EXISTS companion_record (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  child_id      TEXT NOT NULL,
  date          TEXT,
  duration_sec  INTEGER,
  open_count    INTEGER,
  word_count    INTEGER,
  stars         INTEGER,
  created_at    TEXT
);
CREATE INDEX IF NOT EXISTS idx_record_child ON companion_record(child_id, date);

-- 单次陪伴会话的星星快照：客户端防抖同步 + 结束页以服务端为准
CREATE TABLE IF NOT EXISTS companion_session (
  session_id   TEXT PRIMARY KEY,
  child_id     TEXT NOT NULL,
  date         TEXT,
  stars        INTEGER NOT NULL DEFAULT 0,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  updated_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_session_child ON companion_session(child_id, date);

CREATE TABLE IF NOT EXISTS child_progress (
  child_id        TEXT PRIMARY KEY,
  learned_words   TEXT,
  streak_days     INTEGER,
  last_session_at TEXT,
  updated_at      TEXT
);

CREATE TABLE IF NOT EXISTS parent_pin (
  family_id  TEXT PRIMARY KEY,
  pin_hash   TEXT NOT NULL
);

-- 客户端安装实例：client_id 由 App 首次启动生成并持久化，用来隔离多台设备的
-- 心跳、时长上报、日志上传和服务端下发的指令。
CREATE TABLE IF NOT EXISTS client_device (
  client_id   TEXT PRIMARY KEY,
  label       TEXT,
  platform    TEXT,
  app_version TEXT,
  last_seen   TEXT,
  created_at  TEXT
);

-- 一次「进入对话页」的运行快照（幂等）：客户端每 30 秒上报本次运行的累计时长，
-- 服务端只按 max 的差额补进当天统计，重复 / 乱序上报都不会多算。
CREATE TABLE IF NOT EXISTS session_run (
  run_id       TEXT PRIMARY KEY,
  client_id    TEXT,
  child_id     TEXT NOT NULL,
  session_id   TEXT,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  date         TEXT,
  started_at   TEXT,
  updated_at   TEXT
);
CREATE INDEX IF NOT EXISTS idx_run_child ON session_run(child_id, date);

-- 服务端下发给客户端的一次性指令（客户端心跳时领取，执行后 ack）。
CREATE TABLE IF NOT EXISTS client_command (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id    TEXT NOT NULL,
  type         TEXT NOT NULL,
  params       TEXT,
  status       TEXT NOT NULL DEFAULT 'pending', -- pending / delivered / done / failed
  created_at   TEXT,
  delivered_at TEXT,
  acked_at     TEXT,
  result       TEXT
);
CREATE INDEX IF NOT EXISTS idx_cmd_client ON client_command(client_id, status);

-- 每天每个宝宝每个角色的开场话题：首次进入时由 LLM 生成，当天复用
CREATE TABLE IF NOT EXISTS daily_greeting (
  child_id   TEXT NOT NULL,
  role_id    TEXT NOT NULL,
  date       TEXT NOT NULL,
  content    TEXT NOT NULL,
  created_at TEXT,
  PRIMARY KEY (child_id, role_id, date)
);

-- 每周学习计划（周一生成，一次生成 7 天）
CREATE TABLE IF NOT EXISTS learning_plan (
  child_id   TEXT NOT NULL,
  week_start TEXT NOT NULL, -- 周一 YYYY-MM-DD
  source     TEXT,          -- llm / fallback
  created_at TEXT,
  PRIMARY KEY (child_id, week_start)
);

-- 计划里每天的目标词；words 是 JSON: [{"en":"cat","zh":"猫"}, ...]
CREATE TABLE IF NOT EXISTS learning_plan_day (
  child_id   TEXT NOT NULL,
  date       TEXT NOT NULL,
  week_start TEXT NOT NULL,
  day_index  INTEGER NOT NULL, -- 0=周一 … 6=周日
  theme      TEXT,
  words      TEXT NOT NULL,
  created_at TEXT,
  PRIMARY KEY (child_id, date)
);
CREATE INDEX IF NOT EXISTS idx_plan_day_week ON learning_plan_day(child_id, week_start);

-- 词典兜底：内置词库没有的长尾词，用 LLM 生成儿童版释义 + 例句后永久缓存
CREATE TABLE IF NOT EXISTS dict_enrichment (
  word       TEXT PRIMARY KEY,
  zh         TEXT NOT NULL,
  example_en TEXT,
  example_zh TEXT,
  created_at TEXT
);

-- 单词掌握度 + 间隔重复：聊天里出现过的计划词逐轮累积 heard/said，按掌握度安排复习日
CREATE TABLE IF NOT EXISTS word_learning (
  child_id         TEXT NOT NULL,
  word             TEXT NOT NULL,
  zh               TEXT,
  first_seen_date  TEXT,
  last_seen_date   TEXT,
  heard_count      INTEGER NOT NULL DEFAULT 0,
  said_count       INTEGER NOT NULL DEFAULT 0,
  mastery          INTEGER NOT NULL DEFAULT 0, -- 0-5，每次宝宝主动说出 +1
  next_review_date TEXT,                       -- 到期后由 learningHint 拉回复习
  updated_at       TEXT,
  PRIMARY KEY (child_id, word)
);
CREATE INDEX IF NOT EXISTS idx_word_review ON word_learning(child_id, next_review_date);

-- 睡前故事：每天每个宝宝每个角色生成一次，当天复用（TTS 也有磁盘缓存）
CREATE TABLE IF NOT EXISTS bedtime_story (
  child_id   TEXT NOT NULL,
  role_id    TEXT NOT NULL,
  date       TEXT NOT NULL,
  content    TEXT NOT NULL,
  created_at TEXT,
  PRIMARY KEY (child_id, role_id, date)
);
