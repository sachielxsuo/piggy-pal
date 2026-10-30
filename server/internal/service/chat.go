package service

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strconv"
	"strings"
	"time"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/dict"
	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/store"
)

// ASRRecognizer 抽象语音识别依赖，便于测试时注入 fake。
type ASRRecognizer interface {
	Enabled() bool
	Recognize(audioB64, voiceFormat string) (string, error)
}

// ChatService 编排 ASR → LLM → TTS 整条对话链路。
type ChatService struct {
	store   *store.Store
	llm     *LLMService
	tts     *TTSService
	asr     ASRRecognizer
	guard   *GuardService
	roles   *config.RolesConfig
	prompts *config.PromptsConfig
	words   *dict.Dictionary
}

// NewChatService 组装对话服务。
func NewChatService(
	st *store.Store,
	llm *LLMService,
	tts *TTSService,
	asr ASRRecognizer,
	guard *GuardService,
	roles *config.RolesConfig,
	prompts *config.PromptsConfig,
) *ChatService {
	return &ChatService{store: st, llm: llm, tts: tts, asr: asr, guard: guard, roles: roles, prompts: prompts}
}

// findRole 根据 role_id 找角色配置。
func (s *ChatService) findRole(roleID string) *config.Role {
	for i := range s.roles.Roles {
		if s.roles.Roles[i].RoleID == roleID {
			return &s.roles.Roles[i]
		}
	}
	return nil
}

// Handle 处理一次对话请求：输入文本或音频，返回回复文本 + TTS 音频。
func (s *ChatService) Handle(ctx context.Context, childID string, req *model.ChatRequest) (*model.ChatResponse, error) {
	start := time.Now()
	role := s.findRole(req.RoleID)
	if role == nil {
		return nil, fmt.Errorf("未知角色: %s", req.RoleID)
	}

	resp := &model.ChatResponse{}
	slog.InfoContext(ctx, "chat 开始",
		"child_id", childID, "role_id", req.RoleID,
		"text_len", len(req.Text), "audio_len", len(req.AudioB64))

	// 1. 确定输入文本：优先文本，其次语音识别
	childText, hadAudio, err := s.resolveChildText(ctx, childID, req)
	if err != nil {
		return nil, err
	}
	resp.ChildText = childText

	// 有语音但识别为空：温和引导，不落库、不走 LLM，避免宝宝误触发得到冷冰冰的报错
	if childText == "" && hadAudio {
		slog.WarnContext(ctx, "ASR 识别为空，走温和引导", "child_id", childID, "role_id", req.RoleID)
		replyText := fallbackNoHearReply(role)
		if s.tts.Enabled() {
			if audio, err := s.synthesizeRole(role, replyText); err == nil {
				resp.AudioB64 = audio
				resp.AudioFormat = "mp3"
				slog.InfoContext(ctx, "引导 TTS 合成完成", "child_id", childID, "audio_len", len(audio))
			} else {
				slog.WarnContext(ctx, "引导 TTS 合成失败，降级纯文本", "child_id", childID, "err", err)
			}
		}
		resp.ReplyText = replyText
		resp.Stars = 0
		resp.SessionID = req.SessionID
		if sessionStars, err := s.store.GetSessionStars(childID, req.SessionID); err == nil {
			resp.SessionStars = sessionStars
		}
		slog.InfoContext(ctx, "chat 完成(引导)", "child_id", childID,
			"cost_ms", time.Since(start).Milliseconds())
		return resp, nil
	}

	// 2-5. 护栏 → 历史 → system prompt → LLM
	childText, replyText, err := s.generateReply(ctx, childID, role, childText)
	if err != nil {
		return nil, err
	}

	// 6. TTS 合成（失败不阻断，纯文本返回兜底）
	if s.tts.Enabled() {
		if audio, err := s.synthesizeRole(role, replyText); err == nil {
			resp.AudioB64 = audio
			resp.AudioFormat = "mp3"
		} else {
			slog.WarnContext(ctx, "TTS 合成失败，降级纯文本", "child_id", childID, "err", err)
		}
	}

	// 7. 落库（child + ai 两条）
	// 目标词状态必须在落库前算：这时今天的 child 消息还不包含这一轮。
	targetWords, targetBonus := s.targetWordTurn(ctx, childID, childText, replyText)
	_ = s.store.SaveMessage(&model.ChatMessage{ChildID: childID, RoleID: role.RoleID, Speaker: "child", Content: childText})
	_ = s.store.SaveMessage(&model.ChatMessage{ChildID: childID, RoleID: role.RoleID, Speaker: "ai", Content: replyText})

	// 8. 累加当天星星 / 英文词数（统计失败不影响对话返回）
	// 星星规则：只有说英文单词才有星星，1 个英文单词 1 颗，单轮最多 3 颗；
	// 今天第一次说中目标词额外 +2（单轮上限 5 颗）。
	wordCount := CountWords(childText)
	earned := StarsForWords(wordCount) + targetBonus
	sessionStars := 0
	if n, err := s.store.RecordChatActivity(childID, req.SessionID, earned, wordCount); err != nil {
		slog.WarnContext(ctx, "累加陪伴统计失败", "child_id", childID, "err", err)
	} else {
		sessionStars = n
	}
	s.recordWordLearning(ctx, childID, childText, replyText)

	resp.ReplyText = replyText
	resp.Stars = earned
	resp.WordCount = wordCount
	resp.SessionID = req.SessionID
	resp.SessionStars = sessionStars
	resp.TargetBonus = targetBonus
	resp.TargetWords = targetWords
	slog.InfoContext(ctx, "chat 完成", "child_id", childID, "role_id", req.RoleID,
		"reply_len", len(replyText), "audio_len", len(resp.AudioB64),
		"words", wordCount, "stars", earned, "target_bonus", targetBonus,
		"session_stars", sessionStars,
		"cost_ms", time.Since(start).Milliseconds())
	return resp, nil
}

// Speak 按角色音色把一段已有文本合成为语音，用于重播历史消息。
// TTS 带「文本 + 音色」磁盘缓存，历史里同一条消息重播不会重复计费。
func (s *ChatService) Speak(ctx context.Context, roleID, text string) (string, error) {
	return s.speakAt(ctx, roleID, text, 1.0)
}

// SpeakSlow 用更慢的语速合成同一句话，给 4-6 岁宝宝跟读用。
// 0.75 倍听感上明显放慢，又不会慢到失真（TTS 服务下限 0.6）。
func (s *ChatService) SpeakSlow(ctx context.Context, roleID, text string) (string, error) {
	return s.speakAt(ctx, roleID, text, slowSpeedFactor)
}

// slowSpeedFactor 慢速重播的倍率。
const slowSpeedFactor = 0.75

func (s *ChatService) speakAt(ctx context.Context, roleID, text string, factor float64) (string, error) {
	role := s.findRole(roleID)
	if role == nil {
		return "", ErrRoleNotFound
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return "", fmt.Errorf("合成文本为空")
	}
	if !s.tts.Enabled() {
		return "", fmt.Errorf("TTS 未配置")
	}
	return s.synthesizeRoleAtSpeed(role, text, factor)
}

// Goodbye 生成结束页内容：道别 + 星星结算 + 预告明日。
// 不走 LLM，保证每次结束语稳定、可控，并按当前角色音色合成 TTS。
func (s *ChatService) Goodbye(ctx context.Context, roleID string, stars int) (*model.GoodbyeResponse, error) {
	role := s.findRole(roleID)
	if role == nil {
		return nil, fmt.Errorf("未知角色: %s", roleID)
	}
	text := s.buildGoodbyeText(role, stars)
	resp := &model.GoodbyeResponse{ReplyText: text, Stars: stars}
	if s.tts.Enabled() {
		if audio, err := s.synthesizeRole(role, text); err == nil {
			resp.AudioB64 = audio
			resp.AudioFormat = "mp3"
		} else {
			slog.WarnContext(ctx, "道别 TTS 合成失败，降级纯文本", "role_id", roleID, "err", err)
		}
	}
	slog.InfoContext(ctx, "生成结束页", "role_id", roleID, "stars", stars)
	return resp, nil
}

// buildGoodbyeText 用 prompts.yaml 的 preview 步骤拼出「星星结算 + 预告明日」。
func (s *ChatService) buildGoodbyeText(role *config.Role, stars int) string {
	preview := "明天我们再一起玩哦！"
	if s.prompts != nil {
		for _, step := range s.prompts.DailyFlow {
			if step.Step != "preview" || strings.TrimSpace(step.Text) == "" {
				continue
			}
			preview = strings.TrimSpace(step.Text)
			if role != nil && role.Name != "" {
				preview = strings.ReplaceAll(preview, "{name}", role.Name)
			}
			break
		}
	}
	if stars > 0 {
		return fmt.Sprintf("今天玩得真开心！你一共拿到 %d 颗小星星，太棒啦。%s", stars, preview)
	}
	return fmt.Sprintf("今天玩得真开心！%s", preview)
}

// wordRE 匹配英文单词（含 I'm / don't 这类缩写），中文音节不计入 word_count。
var wordRE = regexp.MustCompile(`[A-Za-z]+(?:['’][A-Za-z]+)*`)

// CountWords 统计宝宝一句话里的英文单词数，用于累计开口词数。
func CountWords(s string) int {
	return len(wordRE.FindAllString(s, -1))
}

// StarsForWords 计算单轮对话奖励星星：1 个英文单词 1 颗，单轮最多 3 颗。
// 只说中文 / 只有语气词 → 0 颗，确保星星真正鼓励英文输出。
func StarsForWords(words int) int {
	if words <= 0 {
		return 0
	}
	if words > 3 {
		return 3
	}
	return words
}

// fallbackNoHearReply 生成「识别为空」时的温和引导话术（按角色名个性化）。
func fallbackNoHearReply(role *config.Role) string {
	if role == nil || role.Name == "" {
		return "嗯？没听清哦，再大声说一次好不好？"
	}
	return fmt.Sprintf("嗯？%s没听清哦，再大声说一次给%s听好不好？", role.Name, role.Name)
}

func (s *ChatService) buildSystemPrompt(role *config.Role, child *model.Child) string {
	parts := []string{}
	if s.prompts != nil {
		if s.prompts.System.Base != "" {
			parts = append(parts, s.prompts.System.Base)
		}
		if s.prompts.System.Safety != "" {
			parts = append(parts, "安全要求："+s.prompts.System.Safety)
		}
	}
	if role.Persona != "" {
		parts = append(parts, "角色设定："+role.Persona)
	}
	if id := childIdentity(child); id != "" {
		parts = append(parts, id)
	}
	if flow := s.buildDailyFlow(role); flow != "" {
		parts = append(parts, flow)
	}
	return strings.Join(parts, "\n")
}

// dailyFlowLabels 把 prompts.yaml 里的英文 step 映射成中文提示，方便 LLM 理解节奏。
var dailyFlowLabels = map[string]string{
	"greeting": "问候开场",
	"activity": "自由互动",
	"reward":   "星星鼓励",
	"goodbye":  "温柔道别",
	"preview":  "预告下次",
}

// buildDailyFlow 把 prompts.yaml 的五步陪伴流程注入 system prompt。
// 只作为「节奏参考」而非逐字脚本，避免 LLM 每轮都念模板、或过早说再见。
func (s *ChatService) buildDailyFlow(role *config.Role) string {
	if s.prompts == nil || len(s.prompts.DailyFlow) == 0 {
		return ""
	}
	lines := make([]string, 0, len(s.prompts.DailyFlow))
	for _, step := range s.prompts.DailyFlow {
		text := strings.TrimSpace(step.Text)
		if text == "" {
			continue
		}
		if role != nil && role.Name != "" {
			text = strings.ReplaceAll(text, "{name}", role.Name)
		}
		label := dailyFlowLabels[step.Step]
		if label == "" {
			label = step.Step
		}
		lines = append(lines, fmt.Sprintf("%d. %s：%s", len(lines)+1, label, text))
	}
	if len(lines) == 0 {
		return ""
	}
	return "每日陪伴节奏（按顺序自然推进，参考话术不要机械照读；根据宝宝的回应灵活停留或跳过。只有宝宝想结束或对话接近尾声时，才使用「温柔道别」和「预告下次」，不要每轮都说再见）：\n" +
		strings.Join(lines, "\n")
}

// childIdentity 生成「正在对话的宝宝」身份描述，注入 system prompt 让 LLM 更自然称呼宝宝。
func childIdentity(child *model.Child) string {
	if child == nil {
		return ""
	}
	cn := strings.TrimSpace(child.Name)
	en := strings.TrimSpace(child.EnName)

	var b strings.Builder
	switch {
	case cn != "" && en != "":
		// 称呼一致性：真实对话里出现过同一句里「小雨」和「Rain」混着叫，
		// 孩子会分不清在叫谁。中文句用中文名、英文句用英文名，是孩子能理解的规则。
		b.WriteString(fmt.Sprintf("正在对话的宝宝：中文名「%s」，英文名「%s」。称呼规则："+
			"说中文时只叫「%s」，说英文时才用「%s」；不要在同一句里中英文名混着叫，"+
			"也不要把两个名字连在一起叫。", cn, en, cn, en))
	case cn != "":
		b.WriteString(fmt.Sprintf("正在对话的宝宝：中文名「%s」。请自然地称呼宝宝的名字。", cn))
	case en != "":
		b.WriteString(fmt.Sprintf("正在对话的宝宝：英文名「%s」。请自然地称呼宝宝的名字。", en))
	default:
		return ""
	}
	if child.Age > 0 {
		b.WriteString(fmt.Sprintf("宝宝 %d 岁，请按这个年龄控制句子长度和词汇难度。", child.Age))
	}
	if p := strings.TrimSpace(child.Preferences); p != "" {
		b.WriteString(fmt.Sprintf("宝宝喜欢：%s。可以在聊天里自然带入这些兴趣，但不要每句都提。", truncateRunes(p, 60)))
	}
	return b.String()
}

// truncateRunes 按字符截断，避免偏好文本过长挤占 prompt。
func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// synthesizeRole 按角色配置合成语音，统一处理普通音色与一句话版复刻音色。
func (s *ChatService) synthesizeRole(role *config.Role, text string) (string, error) {
	return s.synthesizeRoleAtSpeed(role, text, 1.0)
}

// synthesizeRoleAtSpeed 按倍率调整角色语速后合成；factor=1 就是正常语速。
func (s *ChatService) synthesizeRoleAtSpeed(role *config.Role, text string, factor float64) (string, error) {
	voiceType, fastVoiceType := voiceParams(role)
	return s.tts.SynthesizeWithFallback(
		text, voiceType, fastVoiceType, roleSpeed(role, factor), role.FallbackVoiceType())
}

// roleSpeed 计算实际语速，并夹到 TTS 支持的 0.6–2.0 区间。
// 慢速重播用它，避免角色本身语速偏低时（乔治 0.85）乘完倍率掉出下限。
func roleSpeed(role *config.Role, factor float64) float64 {
	speed := role.TTSSpeed() * factor
	if speed < 0.6 {
		return 0.6
	}
	if speed > 2.0 {
		return 2.0
	}
	return speed
}

// voiceParams 解析角色音色：填了 fast_voice_id 就用一句话复刻，
// 否则用 voice_id 的数字音色。
func voiceParams(role *config.Role) (int64, string) {
	if role == nil {
		return parseVoiceType(""), ""
	}
	if fast := strings.TrimSpace(role.FastVoiceID); fast != "" {
		// 腾讯云约定：使用一句话版声音复刻时 VoiceType 固定为 200000000
		return 200000000, fast
	}
	return parseVoiceType(role.VoiceID), ""
}

// parseVoiceType 把 roles.yaml 的 voice_id（数字字符串）转 int64，非法则用默认音色。
func parseVoiceType(voiceID string) int64 {
	n, err := strconv.ParseInt(strings.TrimSpace(voiceID), 10, 64)
	if err != nil || n == 0 {
		n = 403000 // 默认：云小朵（特色女童声）
	}
	return n
}
