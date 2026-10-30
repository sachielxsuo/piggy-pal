package service

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"time"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
)

// StreamEvent 是流式对话推给客户端的一个阶段事件。
//
// 顺序固定：asr → reply → audio（可能多段）。
// 这样宝宝说完话后，识别文本、回复文本、语音分别到达，
// 不用等整条链路（ASR + LLM + TTS）全部跑完才看到任何反馈。
type StreamEvent struct {
	Type         string             `json:"type"`
	ChildText    string             `json:"child_text,omitempty"`
	ReplyText    string             `json:"reply_text,omitempty"`
	AudioB64     string             `json:"audio_b64,omitempty"`
	AudioFormat  string             `json:"audio_format,omitempty"`
	Stars        int                `json:"stars"`
	WordCount    int                `json:"word_count"`
	SessionID    string             `json:"session_id,omitempty"`
	SessionStars int                `json:"session_stars"`
	Index        int                `json:"index"`
	Guide        bool               `json:"guide,omitempty"`
	TargetBonus  int                `json:"target_bonus"`
	TargetWords  []model.TargetWord `json:"target_words,omitempty"`
}

// RoleExists 供 HTTP 层在开始流式响应前校验角色，避免先回 200 再报错。
func (s *ChatService) RoleExists(roleID string) bool { return s.findRole(roleID) != nil }

// HandleStream 按阶段执行对话：识别完成先推文本，LLM 完成推回复，TTS 按句推送音频。
// emit 返回错误时（通常是客户端断开）立即停止，后续阶段不再执行。
func (s *ChatService) HandleStream(ctx context.Context, childID string, req *model.ChatRequest, emit func(StreamEvent) error) error {
	start := time.Now()
	role := s.findRole(req.RoleID)
	if role == nil {
		return fmt.Errorf("未知角色: %s", req.RoleID)
	}
	slog.InfoContext(ctx, "stream chat 开始",
		"child_id", childID, "role_id", req.RoleID,
		"text_len", len(req.Text), "audio_len", len(req.AudioB64))

	childText, hadAudio, err := s.resolveChildText(ctx, childID, req)
	if err != nil {
		return err
	}
	// 先推识别结果：客户端马上能把宝宝说的话显示出来（不再等 LLM/TTS）
	if err := emit(StreamEvent{Type: "asr", ChildText: childText}); err != nil {
		return err
	}

	// 有语音但识别为空：温和引导，不落库、不走 LLM
	if childText == "" && hadAudio {
		replyText := fallbackNoHearReply(role)
		sessionStars := 0
		if n, err := s.store.GetSessionStars(childID, req.SessionID); err == nil {
			sessionStars = n
		}
		if err := emit(StreamEvent{
			Type: "reply", ReplyText: replyText, SessionID: req.SessionID,
			SessionStars: sessionStars, Guide: true,
		}); err != nil {
			return err
		}
		if err := s.emitAudio(ctx, role, replyText, emit); err != nil {
			return err
		}
		slog.InfoContext(ctx, "stream chat 完成(引导)", "child_id", childID,
			"cost_ms", time.Since(start).Milliseconds())
		return nil
	}

	childText, replyText, err := s.generateReply(ctx, childID, role, childText)
	if err != nil {
		return err
	}

	// 落库 + 结算星星（在推 reply 之前完成，客户端拿到的一定是权威值）
	// 目标词状态必须在落库前算：这时今天的 child 消息还不包含这一轮。
	targetWords, targetBonus := s.targetWordTurn(ctx, childID, childText, replyText)
	_ = s.store.SaveMessage(&model.ChatMessage{ChildID: childID, RoleID: role.RoleID, Speaker: "child", Content: childText})
	_ = s.store.SaveMessage(&model.ChatMessage{ChildID: childID, RoleID: role.RoleID, Speaker: "ai", Content: replyText})

	wordCount := CountWords(childText)
	earned := StarsForWords(wordCount) + targetBonus
	sessionStars := 0
	if n, err := s.store.RecordChatActivity(childID, req.SessionID, earned, wordCount); err != nil {
		slog.WarnContext(ctx, "累加陪伴统计失败", "child_id", childID, "err", err)
	} else {
		sessionStars = n
	}
	// 间隔重复：累积 heard/said + 安排下次复习日（失败只记日志）
	s.recordWordLearning(ctx, childID, childText, replyText)

	if err := emit(StreamEvent{
		Type: "reply", ReplyText: replyText, Stars: earned, WordCount: wordCount,
		SessionID: req.SessionID, SessionStars: sessionStars,
		TargetBonus: targetBonus, TargetWords: targetWords,
	}); err != nil {
		return err
	}

	// 按句合成：第一句先到、先播，不用等整段回复合成完
	if err := s.emitAudio(ctx, role, replyText, emit); err != nil {
		return err
	}

	slog.InfoContext(ctx, "stream chat 完成", "child_id", childID, "role_id", req.RoleID,
		"reply_len", len(replyText), "words", wordCount, "stars", earned,
		"session_stars", sessionStars, "cost_ms", time.Since(start).Milliseconds())
	return nil
}

// emitAudio 把回复按句切开，逐句合成并推送。
// 某一句合成失败只跳过该句，不影响后续句子和文本展示。
func (s *ChatService) emitAudio(ctx context.Context, role *config.Role, text string, emit func(StreamEvent) error) error {
	if s.tts == nil || !s.tts.Enabled() {
		return nil
	}
	parts := splitSentences(text)
	for i, part := range parts {
		audio, err := s.synthesizeRole(role, part)
		if err != nil {
			slog.WarnContext(ctx, "TTS 分段合成失败，跳过该段",
				"role_id", role.RoleID, "index", i, "err", err)
			continue
		}
		if err := emit(StreamEvent{
			Type: "audio", AudioB64: audio, AudioFormat: "mp3", Index: i,
		}); err != nil {
			return err
		}
	}
	return nil
}

// 句子结束符：中文标点 + 英文句号/问号/感叹号 + 换行。
// 句号也切：回复通常很短，"Mr. Smith" 这类缩写不在 3-6 岁对话里出现。
var sentenceSep = regexp.MustCompile(`[。！？!?；;…\n]+|\.+`)

// splitSentences 按句子切分，保留标点，供逐句 TTS 使用。
// 没有可切分的标点时返回整段，保证至少有一段。
func splitSentences(text string) []string {
	text = strings.TrimSpace(text)
	if text == "" {
		return nil
	}
	var out []string
	last := 0
	for _, loc := range sentenceSep.FindAllStringIndex(text, -1) {
		part := strings.TrimSpace(text[last:loc[1]])
		if part != "" {
			out = append(out, part)
		}
		last = loc[1]
	}
	if rest := strings.TrimSpace(text[last:]); rest != "" {
		out = append(out, rest)
	}
	if len(out) == 0 {
		return []string{text}
	}
	return out
}
