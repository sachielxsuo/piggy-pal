package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"sync"
	"time"

	"piggy-pal/server/internal/dict"
	"piggy-pal/server/internal/model"
)

// 内置词典是全局只读数据，进程内只加载一次。
var (
	dictOnce    sync.Once
	sharedDict  *dict.Dictionary
	dictLoadErr error
)

// SetDictionary 注入已加载的词典（main 里显式加载，便于启动日志）。
func (s *ChatService) SetDictionary(d *dict.Dictionary) { s.words = d }

func (s *ChatService) dictionary() *dict.Dictionary {
	if s.words != nil {
		return s.words
	}
	dictOnce.Do(func() {
		sharedDict, dictLoadErr = dict.Load()
	})
	return sharedDict
}

// LookupWord 查一个单词：内置词库 → LLM 补全 → 补上原句与发音。
func (s *ChatService) LookupWord(ctx context.Context, childID, roleID, raw string, msgID int64) (*dict.Entry, error) {
	word := dict.Normalize(raw)
	if word == "" {
		return nil, fmt.Errorf("不是可查询的英文单词：%q", raw)
	}
	d := s.dictionary()
	if d == nil {
		return nil, fmt.Errorf("词典未加载：%v", dictLoadErr)
	}

	entry, ok := d.Lookup(word)
	if !ok {
		entry = s.enrichWord(ctx, word)
	}
	if entry == nil {
		entry = &dict.Entry{Word: word, Lemma: word}
	}
	if entry.Found {
		s.attachContext(childID, entry, msgID)
		s.attachAudio(d, roleID, entry)
	}
	slog.InfoContext(ctx, "查词", "word", word, "lemma", entry.Lemma,
		"level", entry.Level, "found", entry.Found, "audio", entry.AudioSource)
	return entry, nil
}

// attachContext 用点击所在的那条消息做「语境例句」。
func (s *ChatService) attachContext(childID string, entry *dict.Entry, msgID int64) {
	if msgID <= 0 || childID == "" || s.store == nil {
		return
	}
	msg, err := s.store.GetMessage(childID, msgID)
	if err != nil || msg == nil {
		return
	}
	entry.Context = dict.FindContext(msg.Content, entry.Lemma)
}

// attachAudio 优先真人录音（正常 + 慢读），没有录音才退回 TTS。
func (s *ChatService) attachAudio(d *dict.Dictionary, roleID string, entry *dict.Entry) {
	if normal, slow, credit, ok := d.Audio(entry.Word); ok {
		entry.AudioB64 = base64.StdEncoding.EncodeToString(normal)
		if len(slow) > 0 {
			entry.AudioSlowB64 = base64.StdEncoding.EncodeToString(slow)
		}
		entry.AudioSource = "human"
		entry.AudioCredit = credit
		return
	}
	if s.tts == nil || !s.tts.Enabled() {
		return
	}
	role := s.findRole(roleID)
	speed := role.TTSSpeed()
	audio, err := s.synthesizeRole(role, entry.Lemma)
	if err != nil {
		slog.Warn("词典 TTS 合成失败", "word", entry.Lemma, "err", err)
		return
	}
	entry.AudioB64 = audio
	entry.AudioSource = "tts"
	voiceType, fast := voiceParams(role)
	slowSpeed := math.Max(0.6, speed*0.72)
	if slow, err := s.tts.SynthesizeWithFallback(
		entry.Lemma, voiceType, fast, slowSpeed, role.FallbackVoiceType()); err == nil {
		entry.AudioSlowB64 = slow
	}
}

const dictEnrichPrompt = `你是儿童英语词典编辑。请为 4-6 岁中国孩子解释一个英文单词。

只输出一个 JSON 对象，不要 markdown 代码块，不要多余文字：
{"zh":"恐龙","example_en":"The dinosaur is big.","example_zh":"这只恐龙很大。"}

要求：
1. zh 只写最常见的一个意思，不超过 8 个汉字，不要词性标注，不要英文；
2. example_en 3-8 个单词，只用最基础的词，语法正确，以句号结尾；
3. example_zh 是这句英文的自然中文翻译；
4. 内容必须适合幼儿，不能出现暴力、恐怖、成人、技术、商业内容。`

type enrichedReply struct {
	Zh        string `json:"zh"`
	ExampleEn string `json:"example_en"`
	ExampleZh string `json:"example_zh"`
}

// enrichWord 处理内置词库没有的长尾词：查缓存 → LLM 生成 → 落库缓存。
func (s *ChatService) enrichWord(ctx context.Context, word string) *dict.Entry {
	if s.store != nil {
		if cached, err := s.store.GetDictEnrichment(word); err == nil && cached != nil {
			return &dict.Entry{
				Word:    word,
				Lemma:   word,
				Senses:  []string{cached.Zh},
				Example: &dict.Sentence{En: cached.ExampleEn, Zh: cached.ExampleZh},
				Level:   "enriched",
				Found:   true,
			}
		}
	}
	if s.llm == nil || !s.llm.Enabled() {
		return nil
	}
	callCtx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()
	reply, err := s.llm.Chat(callCtx, dictEnrichPrompt, nil, word)
	if err != nil {
		slog.Warn("词典 LLM 补全失败", "word", word, "err", err)
		return nil
	}
	var parsed enrichedReply
	if err := json.Unmarshal([]byte(stripCodeFence(reply)), &parsed); err != nil {
		slog.Warn("词典 LLM 返回不是合法 JSON", "word", word, "reply", truncate(reply, 120))
		return nil
	}
	if !validEnrichment(&parsed) {
		slog.Warn("词典 LLM 返回内容不合格", "word", word, "reply", truncate(reply, 120))
		return nil
	}
	if s.store != nil {
		if err := s.store.SaveDictEnrichment(&model.DictEnrichment{
			Word: word, Zh: parsed.Zh, ExampleEn: parsed.ExampleEn, ExampleZh: parsed.ExampleZh,
		}); err != nil {
			slog.Warn("词典补全结果落库失败", "word", word, "err", err)
		}
	}
	return &dict.Entry{
		Word:    word,
		Lemma:   word,
		Senses:  []string{parsed.Zh},
		Example: &dict.Sentence{En: parsed.ExampleEn, Zh: parsed.ExampleZh},
		Level:   "enriched",
		Found:   true,
	}
}

var dictBadWords = []string{"暴力", "杀", "血", "恐怖", "色情", "性", "枪", "毒"}

func validEnrichment(r *enrichedReply) bool {
	r.Zh = strings.TrimSpace(r.Zh)
	r.ExampleEn = strings.TrimSpace(r.ExampleEn)
	r.ExampleZh = strings.TrimSpace(r.ExampleZh)
	if r.Zh == "" || len([]rune(r.Zh)) > 12 {
		return false
	}
	for _, bad := range dictBadWords {
		if strings.Contains(r.Zh, bad) {
			return false
		}
	}
	if r.ExampleZh == "" || !strings.ContainsAny(r.ExampleZh, "。！？") {
		return false
	}
	words := strings.Fields(r.ExampleEn)
	if len(words) < 3 || len(words) > 10 {
		return false
	}
	if !strings.HasSuffix(r.ExampleEn, ".") && !strings.HasSuffix(r.ExampleEn, "!") && !strings.HasSuffix(r.ExampleEn, "?") {
		return false
	}
	for _, w := range words {
		if len([]rune(w)) > 20 || strings.ContainsAny(w, "`~#$%^&*") {
			return false
		}
	}
	return true
}

func stripCodeFence(s string) string {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, "```") {
		return s
	}
	if i := strings.Index(s, "\n"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.TrimSuffix(strings.TrimSpace(s), "```")
	return strings.TrimSpace(s)
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
