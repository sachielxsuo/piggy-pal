package model

// Child 宝宝档案（SQLite child 表）。
type Child struct {
	ChildID     string `json:"child_id"`
	FamilyID    string `json:"family_id"`
	Name        string `json:"name"`    // 中文名
	EnName      string `json:"en_name"` // 英文名
	Age         int    `json:"age"`
	Gender      string `json:"gender"`
	Preferences string `json:"preferences"`
	Avatar      string `json:"avatar"`
	CreatedAt   string `json:"created_at"`
}

// ChatMessage 一条对话记录（SQLite chat_message 表）。
type ChatMessage struct {
	ID        int64  `json:"id"`
	ChildID   string `json:"child_id"`
	RoleID    string `json:"role_id"`
	Speaker   string `json:"speaker"` // child / ai
	Content   string `json:"content"`
	CreatedAt string `json:"created_at"`
}

// CompanionRecord 一次陪伴记录（SQLite companion_record 表）。
type CompanionRecord struct {
	ID          int64  `json:"id"`
	ChildID     string `json:"child_id"`
	Date        string `json:"date"`
	DurationSec int    `json:"duration_sec"`
	OpenCount   int    `json:"open_count"`
	WordCount   int    `json:"word_count"`
	Stars       int    `json:"stars"`
	CreatedAt   string `json:"created_at"`
}

// ChildProgress 宝宝进度（SQLite child_progress 表）。
type ChildProgress struct {
	ChildID       string `json:"child_id"`
	LearnedWords  string `json:"learned_words"`
	StreakDays    int    `json:"streak_days"`
	LastSessionAt string `json:"last_session_at"`
	UpdatedAt     string `json:"updated_at"`
}

// ChatRequest 客户端发来的对话请求：Text 与 AudioB64 二选一。
type ChatRequest struct {
	RoleID      string `json:"role_id"`
	Text        string `json:"text"`         // 打字输入
	AudioB64    string `json:"audio_b64"`    // 语音输入（base64）
	VoiceFormat string `json:"voice_format"` // 语音格式，默认 m4a
	SessionID   string `json:"session_id"`   // 本次陪伴会话 ID（客户端进入对话页时生成）
}

// ChatResponse 对话回复。
type ChatResponse struct {
	ChildText    string       `json:"child_text"`    // 识别出的宝宝话（语音输入时）
	ReplyText    string       `json:"reply_text"`    // AI 回复文本
	AudioB64     string       `json:"audio_b64"`     // TTS 音频 base64（可能为空）
	AudioFormat  string       `json:"audio_format"`  // TTS 音频格式，如 mp3
	Stars        int          `json:"stars"`         // 本句奖励星星数（只说英文才有）
	WordCount    int          `json:"word_count"`    // 本句宝宝说的英文单词数
	SessionID    string       `json:"session_id"`    // 本次会话 ID（回显）
	SessionStars int          `json:"session_stars"` // 本次会话累计星星（服务端权威值）
	TargetBonus  int          `json:"target_bonus"`  // 说中今日目标词的额外星星
	TargetWords  []TargetWord `json:"target_words,omitempty"`
}

// TargetWord 今日目标词在本轮对话后的状态，供对话页顶部词卡展示。
type TargetWord struct {
	En       string `json:"en"`
	Zh       string `json:"zh"`
	Heard    bool   `json:"heard"`     // 角色今天已经说过
	Said     bool   `json:"said"`      // 宝宝今天已经说出
	JustSaid bool   `json:"just_said"` // 就是这一轮说中的（客户端用来高亮 + 庆祝）
}

// RoleGreetingResponse 角色在首页的语音（自我介绍 + 英文口号）。
type RoleGreetingResponse struct {
	RoleID      string `json:"role_id"`
	Text        string `json:"text"`         // 实际送入 TTS 的文本，便于排查
	AudioB64    string `json:"audio_b64"`    // TTS 音频 base64
	AudioFormat string `json:"audio_format"` // 音频格式，如 mp3
}

// TimeWarningResponse 倒计时语音提醒（剩 2 分钟 / 30 秒）。
// 文案固定、按角色 + 语速走 TTS 磁盘缓存，同一句只会合成一次。
type TimeWarningResponse struct {
	Kind        string `json:"kind"` // 2min / 30s
	Text        string `json:"text"`
	AudioB64    string `json:"audio_b64"`
	AudioFormat string `json:"audio_format"`
}

// DailyGreetingResponse 每日开场话题：每天首次进入角色对话页时生成，当天复用。
type DailyGreetingResponse struct {
	RoleID      string `json:"role_id"`
	Date        string `json:"date"`         // YYYY-MM-DD
	Text        string `json:"text"`         // 中英混排的一句话话题
	AudioB64    string `json:"audio_b64"`    // 角色音色 TTS（可能为空）
	AudioFormat string `json:"audio_format"` // 音频格式，如 mp3
	IsNew       bool   `json:"is_new"`       // 今天首次生成 → 客户端自动播放
}

// SessionRequest 客户端上报一次陪伴会话的时长 / 打开次数。
// 星星和开口数由服务端在对话成功时自动累加，客户端不需要（也不应该）上报。
type SessionRequest struct {
	SessionID   string `json:"session_id"`   // 本次会话 ID，可选
	DurationSec int    `json:"duration_sec"` // 本次陪伴时长（秒）
	OpenCount   int    `json:"open_count"`   // 打开次数，通常为 1
}

// SessionSyncRequest 客户端定期同步「本次会话星星」的绝对值快照。
// 服务端只补差额、不会重复加星，重复上报是安全的。
type SessionSyncRequest struct {
	SessionID string `json:"session_id"`
	Stars     int    `json:"stars"`
}

// GoodbyeRequest 结束页请求：按角色生成道别语 + 预告明日。
type GoodbyeRequest struct {
	RoleID    string `json:"role_id"`
	Stars     int    `json:"stars"`      // 本次会话获得的星星（客户端快照）
	SessionID string `json:"session_id"` // 有会话 ID 时以服务端记录为准
}

// GoodbyeResponse 结束页内容（文本 + 可选 TTS）。
type GoodbyeResponse struct {
	ReplyText   string `json:"reply_text"`
	AudioB64    string `json:"audio_b64"`
	AudioFormat string `json:"audio_format"`
	Stars       int    `json:"stars"` // 服务端结算的本次会话星星
}

// DayStat 某一天的陪伴统计。
type DayStat struct {
	Date        string `json:"date"`
	Stars       int    `json:"stars"`
	WordCount   int    `json:"word_count"`
	DurationSec int    `json:"duration_sec"`
	OpenCount   int    `json:"open_count"`
	Utterances  int    `json:"utterances"` // 宝宝开口次数（chat_message 里 child 发言条数）

	// 学习计划相关：只统计当天计划内的单词，去重。
	PlanWords  int `json:"plan_words"`  // 当天计划词数（通常是 10）
	WordsHeard int `json:"words_heard"` // 角色在对话里说到的计划词数
	WordsSaid  int `json:"words_said"`  // 宝宝自己说出的计划词数
}

// PlanWord 一个计划内的英文单词。
type PlanWord struct {
	En string `json:"en"`
	Zh string `json:"zh"`
}

// PlanDay 学习计划中的一天。
type PlanDay struct {
	Date       string     `json:"date"`
	DayIndex   int        `json:"day_index"` // 0=周一 … 6=周日
	Theme      string     `json:"theme"`
	Words      []PlanWord `json:"words"`
	Heard      int        `json:"heard"`       // 角色说到的词数
	Said       int        `json:"said"`        // 宝宝说出的词数
	HeardWords []string   `json:"heard_words"` // 角色已说到的词（英文）
	SaidWords  []string   `json:"said_words"`  // 宝宝已说出的词（英文）
}

// LearningPlan 一周学习计划（周一到周日）。
type LearningPlan struct {
	ChildID   string    `json:"child_id"`
	WeekStart string    `json:"week_start"` // 周一 YYYY-MM-DD
	Source    string    `json:"source"`     // llm / fallback
	Days      []PlanDay `json:"days"`
	Today     PlanDay   `json:"today"`
}

// DatedMessage 按天统计用的对话片段（只保留日期，不暴露完整时间）。
type DatedMessage struct {
	Date    string `json:"date"`
	Speaker string `json:"speaker"`
	Content string `json:"content"`
}

// ChildStats 宝宝的学习 / 陪伴统计，供星星页和家长报告使用。
type ChildStats struct {
	ChildID         string    `json:"child_id"`
	Today           DayStat   `json:"today"`
	Total           DayStat   `json:"total"`
	Week            []DayStat `json:"week"`
	WeekStars       int       `json:"week_stars"`
	StreakDays      int       `json:"streak_days"`
	TotalUtterances int       `json:"total_utterances"`

	// 间隔重复：今天到期该复习的词数 / 已经掌握（说出 5 次）的词数
	WordsToReview int `json:"words_to_review"`
	WordsMastered int `json:"words_mastered"`
}

// WordLearning 一个词的掌握度记录（SQLite word_learning 表）。
type WordLearning struct {
	ChildID        string `json:"child_id"`
	Word           string `json:"word"`
	Zh             string `json:"zh"`
	FirstSeenDate  string `json:"first_seen_date"`
	LastSeenDate   string `json:"last_seen_date"`
	HeardCount     int    `json:"heard_count"`
	SaidCount      int    `json:"said_count"`
	Mastery        int    `json:"mastery"` // 0-5
	NextReviewDate string `json:"next_review_date"`
}

// Sticker 一张按累计星星解锁的贴纸。
type Sticker struct {
	ID       string `json:"id"`
	Emoji    string `json:"emoji"`
	Name     string `json:"name"`
	Hint     string `json:"hint"`  // 解锁后的一句鼓励 / 小知识
	Stars    int    `json:"stars"` // 解锁所需累计星星
	Unlocked bool   `json:"unlocked"`
}

// StickerBoard 贴纸墙：累计星星 + 全部贴纸 + 下一张待解锁贴纸。
type StickerBoard struct {
	ChildID    string    `json:"child_id"`
	TotalStars int       `json:"total_stars"`
	Stickers   []Sticker `json:"stickers"`
	Next       *Sticker  `json:"next,omitempty"`
}

// UnlockedCount 已解锁的贴纸数。
func (b *StickerBoard) UnlockedCount() int {
	n := 0
	for _, s := range b.Stickers {
		if s.Unlocked {
			n++
		}
	}
	return n
}

// BedtimeStoryResponse 睡前故事：每天一段，可慢速。
type BedtimeStoryResponse struct {
	ChildID     string `json:"child_id"`
	RoleID      string `json:"role_id"`
	Date        string `json:"date"`
	Text        string `json:"text"`
	AudioB64    string `json:"audio_b64"`
	AudioFormat string `json:"audio_format"`
	IsNew       bool   `json:"is_new"`
}

// DictEnrichment 是长尾词的 LLM 补全结果（SQLite dict_enrichment 表）。
type DictEnrichment struct {
	Word      string `json:"word"`
	Zh        string `json:"zh"`
	ExampleEn string `json:"example_en"`
	ExampleZh string `json:"example_zh"`
	CreatedAt string `json:"created_at"`
}
