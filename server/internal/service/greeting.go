package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"
	"unicode"

	"piggy-pal/server/internal/model"
)

// ErrRoleNotFound 角色 ID 不存在。
var ErrRoleNotFound = errors.New("角色不存在")

// 允许送进 TTS 的标点：中英文常用标点，避免表情符号被念成奇怪的字。
const speakablePunct = ".,!?;:'\"()[]{}<>-—–~～，。！？；：、“”‘’（）《》〈〉…·/"

// RoleGreeting 合成角色在首页的语音：先中文自我介绍，再英文口号。
// 音频按「文本 + 音色」走 TTS 磁盘缓存，重复请求不会重复计费。
func (s *ChatService) RoleGreeting(ctx context.Context, roleID string) (*model.RoleGreetingResponse, error) {
	role := s.findRole(roleID)
	if role == nil {
		return nil, ErrRoleNotFound
	}
	if s.tts == nil || !s.tts.Enabled() {
		return nil, fmt.Errorf("TTS 未配置")
	}
	text := speakableText(strings.TrimSpace(role.Catchphrase) + " " + strings.TrimSpace(role.SayEn))
	if text == "" {
		return nil, fmt.Errorf("角色语音文本为空")
	}

	start := time.Now()
	audio, err := s.synthesizeRole(role, text)
	if err != nil {
		slog.ErrorContext(ctx, "角色语音合成失败", "role_id", roleID, "err", err,
			"cost_ms", time.Since(start).Milliseconds())
		return nil, fmt.Errorf("语音合成失败: %w", err)
	}
	slog.InfoContext(ctx, "角色语音合成完成", "role_id", roleID, "text_len", len(text),
		"audio_len", len(audio), "cost_ms", time.Since(start).Milliseconds())

	return &model.RoleGreetingResponse{
		RoleID:      roleID,
		Text:        text,
		AudioB64:    audio,
		AudioFormat: "mp3",
	}, nil
}

// WarmupGreetings 启动时预热所有角色的首页语音。
// 角色文案是配置里固定的：磁盘缓存命中时只是读文件（0 成本），
// 只有首次部署或改了文案才会真正调一次 TTS。
func (s *ChatService) WarmupGreetings(ctx context.Context) {
	if s.tts == nil || !s.tts.Enabled() {
		return
	}
	for i := range s.roles.Roles {
		roleID := s.roles.Roles[i].RoleID
		start := time.Now()
		if _, err := s.RoleGreeting(ctx, roleID); err != nil {
			slog.WarnContext(ctx, "角色语音预热失败", "role_id", roleID, "err", err)
			continue
		}
		slog.InfoContext(ctx, "角色语音预热完成", "role_id", roleID,
			"cost_ms", time.Since(start).Milliseconds())
	}
}

// speakableText 去掉 TTS 读不出来的表情符号和装饰字符，只保留中英文、数字与常用标点。
func speakableText(text string) string {
	var b strings.Builder
	for _, r := range text {
		switch {
		case unicode.IsLetter(r), unicode.IsDigit(r), unicode.IsSpace(r):
			b.WriteRune(r)
		case strings.ContainsRune(speakablePunct, r):
			b.WriteRune(r)
		}
	}
	return strings.Join(strings.Fields(b.String()), " ")
}
