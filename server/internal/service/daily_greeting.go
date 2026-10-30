package service

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
)

const dayLayout = "2006-01-02"

// recentTopicLimit 生成今日话题时回看的历史话题条数，避免连续几天撞题。
const recentTopicLimit = 5

// DailyGreeting 返回今天的开场话题。
// 每天（每个宝宝 + 每个角色）第一次调用时用 LLM 生成并存库，当天后续调用直接复用，
// 不会重复调模型；生成结果按角色音色合成 TTS。
func (s *ChatService) DailyGreeting(ctx context.Context, childID, roleID string) (*model.DailyGreetingResponse, error) {
	role := s.findRole(roleID)
	if role == nil {
		return nil, ErrRoleNotFound
	}
	date := time.Now().Format(dayLayout)
	resp := &model.DailyGreetingResponse{RoleID: roleID, Date: date, AudioFormat: "mp3"}

	// 1. 当天已经生成过 → 直接复用，不再调 LLM
	text, found, err := s.store.GetDailyGreeting(childID, roleID, date)
	if err != nil {
		slog.WarnContext(ctx, "读取今日话题失败，按未生成处理", "child_id", childID, "role_id", roleID, "err", err)
	}
	if found && strings.TrimSpace(text) != "" {
		text = strings.TrimSpace(text)
	} else {
		// 2. 今天第一次进入：让 LLM 生成一个结合宝宝兴趣的新话题
		child, _ := s.store.GetChild(childID)
		recent, _ := s.store.RecentDailyGreetingTexts(childID, roleID, date, recentTopicLimit)

		text = s.generateDailyTopic(ctx, childID, role, child, recent)
		if err := s.store.SaveDailyGreeting(childID, roleID, date, text); err != nil {
			slog.WarnContext(ctx, "保存今日话题失败", "child_id", childID, "role_id", roleID, "err", err)
		} else {
			resp.IsNew = true
			// 只把「今天第一次」的开场白写进对话历史，供后续 LLM 上下文衔接
			_ = s.store.SaveMessage(&model.ChatMessage{
				ChildID: childID, RoleID: roleID, Speaker: "ai", Content: text,
			})
		}
		slog.InfoContext(ctx, "今日话题生成完成", "child_id", childID, "role_id", roleID,
			"text_len", len([]rune(text)), "recent", len(recent))
	}

	resp.Text = text

	// 3. TTS：中英文两行连起来读，换行换成停顿；同文本命中磁盘缓存，失败只降级纯文本
	ttsText := strings.ReplaceAll(text, "\n", " ")
	if s.tts != nil && s.tts.Enabled() {
		if audio, err := s.synthesizeRole(role, ttsText); err == nil {
			resp.AudioB64 = audio
		} else {
			slog.WarnContext(ctx, "今日话题 TTS 合成失败，降级纯文本", "role_id", roleID, "err", err)
		}
	}
	return resp, nil
}

// generateDailyTopic 让 LLM 生成一句中英混排的开场话题；失败 / 重复 / 命中护栏时降级到固定模板。
func (s *ChatService) generateDailyTopic(ctx context.Context, childID string, role *config.Role, child *model.Child, recent []string) string {
	if s.llm != nil && s.llm.Enabled() {
		prompt := buildTopicPrompt(role, child, recent)
		// 开场白也算角色输出：顺便带入 1 个今天的计划词，统计里会计为「听到」。
		if hint := s.greetingPlanHint(ctx, childID); hint != "" {
			prompt += "\n\n" + hint
		}
		for attempt := 0; attempt < 2; attempt++ {
			raw, err := s.llm.Chat(ctx, prompt, nil, "请生成今天的开场话题。")
			if err != nil {
				slog.WarnContext(ctx, "今日话题 LLM 调用失败，使用兜底文案", "role_id", role.RoleID, "err", err)
				break
			}
			text := cleanGeneratedText(raw)
			if text == "" {
				break
			}
			if s.guard != nil && s.guard.ContainsBlocked(text) {
				slog.WarnContext(ctx, "今日话题命中护栏，使用兜底文案", "role_id", role.RoleID)
				break
			}
			if !isBilingualTopic(text) {
				// 模型偶尔只给中文或只给英文：带着更明确的格式要求再试一次
				slog.WarnContext(ctx, "今日话题缺少中英文两版，重试", "role_id", role.RoleID, "text", text)
				prompt += "\n注意：上一次输出的格式不对。必须严格输出两行：第一行是纯中文，第二行是纯英文完整句子（4-8 个英文单词），英文必须是中文那行的翻译。"
				continue
			}
			if containsText(recent, text) {
				// 和最近几天重复了，带着更强的指令再试一次
				prompt += "\n注意：刚才生成的内容和之前重复了，必须换一个完全不同的话题。"
				continue
			}
			return text
		}
	}
	return fallbackDailyTopic(child)
}

// buildTopicPrompt 组装「生成开场话题」的 system prompt。
func buildTopicPrompt(role *config.Role, child *model.Child, recent []string) string {
	parts := []string{
		"你在给一个 3-6 岁的宝宝准备今天的第一句话，用来开启今天的英语陪伴聊天。",
	}
	if role != nil {
		parts = append(parts, fmt.Sprintf("角色：%s（%s）。角色设定：%s", role.Name, role.En, role.Persona))
	}
	if id := childIdentity(child); id != "" {
		parts = append(parts, id)
	}
	topicHint := "动物、颜色、食物、玩具、儿歌、恐龙、天气"
	if child != nil {
		if p := strings.TrimSpace(child.Preferences); p != "" {
			topicHint = truncateRunes(p, 60) + "、" + topicHint
		}
	}
	parts = append(parts, "要求：\n"+
		"- 同时生成中英文两个版本，严格输出两行：\n"+
		"  第一行中文：主动提出今天想一起聊的一个具体话题（从宝宝喜好里选，今天换一个方向），跟宝宝打招呼，25 个汉字以内\n"+
		"  第二行英文：把第一行翻译成简单英文，必须是完整句子（4-8 个英文单词），只出现英文\n"+
		"- 两行意思要一致，英文要简单、适合 3-6 岁宝宝跟读\n"+
		"- 用宝宝的名字打招呼（有英文名就用英文名）\n"+
		"- 语气活泼、有画面感；不要问宝宝「今天想聊什么」，要直接提议\n"+
		"- 只输出这两行，不要编号、引号、解释、表情符号\n"+
		"可选话题方向："+topicHint)
	if len(recent) > 0 {
		parts = append(parts, "最近几天已经聊过这些话题，今天必须换一个不同的：\n- "+strings.Join(recent, "\n- "))
	}
	return strings.Join(parts, "\n")
}

// fallbackDailyTopic LLM 不可用时的兜底开场：固定输出中文 + 英文两行。
func fallbackDailyTopic(child *model.Child) string {
	name := "宝宝"
	topic := "动物"
	if child != nil {
		if en := strings.TrimSpace(child.EnName); en != "" {
			name = en
		} else if cn := strings.TrimSpace(child.Name); cn != "" {
			name = cn
		}
		if p := firstPreference(child.Preferences); p != "" {
			topic = p
		}
	}
	return fmt.Sprintf(
		"嗨，%s！今天我们来聊聊%s吧。\nLet's talk about %s together!",
		name, topic, topicEnglish(topic),
	)
}

// topicEnglish 把常见中文话题映射成简单英文，供兜底英文句使用。
var topicEnglishMap = map[string]string{
	"恐龙": "dinosaurs", "儿歌": "songs", "动物": "animals", "颜色": "colors",
	"食物": "food", "水果": "fruit", "玩具": "toys", "天气": "the weather",
	"音乐": "music", "车": "cars", "汽车": "cars", "绘本": "storybooks",
	"故事": "stories", "数字": "numbers", "形状": "shapes", "游戏": "games",
	"小猪": "piggies", "佩奇": "Peppa", "乔治": "George", "海洋": "the ocean",
	"昆虫": "bugs", "农场": "the farm", "太空": "space",
}

func topicEnglish(topic string) string {
	if en, ok := topicEnglishMap[topic]; ok {
		return en
	}
	return "it"
}

// isBilingualTopic 校验「中文行 + 英文行」两版都在：第一行有中文，第二行是纯英文短句。
func isBilingualTopic(text string) bool {
	lines := splitTopicLines(text)
	if len(lines) < 2 {
		return false
	}
	cn, en := lines[0], lines[1]
	if !hasChinese(cn) {
		return false
	}
	if hasChinese(en) {
		return false
	}
	return englishWordCount(en) >= 3
}

func hasChinese(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

// englishWordCount 数英文单词：只统计纯字母（允许内部撇号）的连续片段。
func englishWordCount(s string) int {
	count := 0
	inWord := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (inWord && r == '\'') {
			if !inWord {
				count++
				inWord = true
			}
			continue
		}
		inWord = false
	}
	return count
}

// splitTopicLines 按行拆开并去掉空行，最多保留两行。
func splitTopicLines(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if v := strings.TrimSpace(line); v != "" {
			out = append(out, v)
		}
		if len(out) == 2 {
			break
		}
	}
	return out
}

// firstPreference 取喜好里的第一个关键词（支持中英文逗号、顿号、分号分隔）。
func firstPreference(prefs string) string {
	fields := strings.FieldsFunc(prefs, func(r rune) bool {
		return r == '、' || r == '，' || r == ',' || r == '；' || r == ';' || r == '/' || r == '|'
	})
	for _, f := range fields {
		if v := strings.TrimSpace(f); v != "" {
			return truncateRunes(v, 12)
		}
	}
	return ""
}

// cleanGeneratedText 清理模型输出：去代码块 / 引号 / 编号 / 「中文：」「英文：」前缀，最多保留两行。
func cleanGeneratedText(raw string) string {
	text := strings.TrimSpace(raw)
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	text = strings.Trim(text, "`\"'“”‘’「」")

	out := make([]string, 0, 2)
	for _, line := range splitTopicLines(text) {
		l := normalizeTopicLine(line)
		if l == "" {
			continue
		}
		out = append(out, truncateRunes(l, 90))
	}
	return strings.Join(out, "\n")
}

// normalizeTopicLine 压掉多余空白、去掉列表符号和语言标签。
func normalizeTopicLine(line string) string {
	l := strings.Join(strings.Fields(line), " ")
	l = strings.TrimSpace(l)
	l = strings.Trim(l, "-•*· ")
	l = trimLeadingNumbering(l)
	l = trimLabelPrefix(l, "中文", "Chinese", "CN")
	l = trimLabelPrefix(l, "英文", "English", "EN")
	l = strings.Trim(l, "`\"'“”‘’「」")
	return strings.TrimSpace(l)
}

// trimLeadingNumbering 去掉行首的「1.」「1、」「1)」编号。
func trimLeadingNumbering(s string) string {
	i := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
	}
	if i == 0 || i >= len(s) {
		return s
	}
	rest := strings.TrimLeft(s[i:], ".、)）:： ")
	if rest != s[i:] {
		return rest
	}
	return s
}

// trimLabelPrefix 去掉「中文：」「English:」这类语言标签前缀。
func trimLabelPrefix(s string, labels ...string) string {
	for _, label := range labels {
		for _, sep := range []string{"：", ":", " ", "-", " - "} {
			prefix := label + sep
			if len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix) {
				return strings.TrimSpace(s[len(prefix):])
			}
		}
	}
	return s
}

// containsText 判断文本是否与历史列表中的某条相同（忽略空白差异）。
func containsText(list []string, text string) bool {
	target := normalizeForCompare(text)
	if target == "" {
		return false
	}
	for _, item := range list {
		if normalizeForCompare(item) == target {
			return true
		}
	}
	return false
}

func normalizeForCompare(s string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(s) {
		if unicode.IsSpace(r) {
			continue
		}
		b.WriteRune(r)
	}
	return b.String()
}
