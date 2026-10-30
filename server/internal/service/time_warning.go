package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"piggy-pal/server/internal/model"
)

// ErrBadWarningKind 倒计时提醒类型不合法。
var ErrBadWarningKind = errors.New("提醒类型不合法")

// 倒计时提醒的两个节点。文案固定，不经过 LLM：
// 4-6 岁对「突然结束」很敏感，提前预告能显著减少情绪崩溃。
var timeWarningTexts = map[string]string{
	"2min": "还有两分钟，我们就要和%s说拜拜啦。想玩的快一点哦！",
	"30s":  "最后三十秒啦，跟%s说再见吧！",
}

// TimeWarning 返回倒计时语音提醒（文本 + 音频）。
// 文本按角色名生成，TTS 磁盘缓存键含文本 + 音色 + 语速，
// 每个角色每个节点只会真正合成一次，之后都是读缓存。
func (s *ChatService) TimeWarning(ctx context.Context, roleID, kind string) (*model.TimeWarningResponse, error) {
	role := s.findRole(roleID)
	if role == nil {
		return nil, ErrRoleNotFound
	}
	tpl, ok := timeWarningTexts[kind]
	if !ok {
		return nil, ErrBadWarningKind
	}

	text := fmt.Sprintf(tpl, role.Name)
	resp := &model.TimeWarningResponse{Kind: kind, Text: text, AudioFormat: "mp3"}

	if s.tts == nil || !s.tts.Enabled() {
		// 没配 TTS 时只返回文案，客户端静默跳过语音，不影响倒计时
		return resp, nil
	}

	start := time.Now()
	audio, err := s.synthesizeRole(role, text)
	if err != nil {
		slog.WarnContext(ctx, "倒计时提醒合成失败，降级为无语音", "role_id", roleID, "kind", kind, "err", err)
		return resp, nil
	}
	resp.AudioB64 = audio
	slog.InfoContext(ctx, "倒计时提醒合成完成", "role_id", roleID, "kind", kind,
		"audio_len", len(audio), "cost_ms", time.Since(start).Milliseconds())
	return resp, nil
}
