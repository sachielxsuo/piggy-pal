package service

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
)

// resolveChildText 确定这一轮的宝宝输入：优先文本，其次语音识别。
// hadAudio 表示请求里带了语音（即使识别结果是空字符串）。
func (s *ChatService) resolveChildText(ctx context.Context, childID string, req *model.ChatRequest) (string, bool, error) {
	childText := strings.TrimSpace(req.Text)
	hadAudio := strings.TrimSpace(req.AudioB64) != ""
	if childText == "" && hadAudio {
		if !s.asr.Enabled() {
			slog.WarnContext(ctx, "ASR 未启用，无法识别语音", "child_id", childID)
			return "", true, fmt.Errorf("语音输入需要配置 CAM 密钥（ASR）")
		}
		asrStart := time.Now()
		recognized, err := s.asr.Recognize(req.AudioB64, req.VoiceFormat)
		if err != nil {
			slog.ErrorContext(ctx, "ASR 识别失败", "child_id", childID,
				"err", err, "cost_ms", time.Since(asrStart).Milliseconds())
			return "", true, fmt.Errorf("ASR 失败: %w", err)
		}
		childText = strings.TrimSpace(recognized)
		slog.InfoContext(ctx, "ASR 识别完成", "child_id", childID,
			"recognized_len", len(childText), "recognized", childText,
			"cost_ms", time.Since(asrStart).Milliseconds())
	}
	if childText == "" && !hadAudio {
		return "", false, fmt.Errorf("输入为空")
	}
	return childText, hadAudio, nil
}

// generateReply 走护栏 → 历史 → system prompt → LLM，返回（可能被护栏替换过的）宝宝文本和回复文本。
func (s *ChatService) generateReply(ctx context.Context, childID string, role *config.Role, childText string) (string, string, error) {
	// 护栏：命中黑名单则替换话题
	if s.guard.ContainsBlocked(childText) {
		childText = "（宝宝说了一些我想换个话题的内容）"
	}

	// 取宝宝档案（注入中英文名到 system prompt）+ 该宝宝与该角色的历史记忆（隔离）
	child, _ := s.store.GetChild(childID)
	history, _ := s.store.RecentMessages(childID, role.RoleID, 20)

	systemPrompt := s.buildSystemPrompt(role, child)
	// 今日词汇计划：只在这一层注入，普通 /chat 和 /chat/stream 共用。
	// 计划每周只生成一次；这里读库 + 统计当天已覆盖的词，开销很小。
	if hint := s.learningHint(ctx, childID, role.RoleID, childText); hint != "" {
		systemPrompt += "\n\n" + hint
	}

	if !s.llm.Enabled() {
		slog.InfoContext(ctx, "LLM 未启用，使用 mock 回复", "child_id", childID)
		return childText, MockReply(childText), nil
	}

	llmHistory := make([]LLMMessage, 0, len(history))
	for _, m := range history {
		r := "user"
		if m.Speaker == "ai" {
			r = "assistant"
		}
		llmHistory = append(llmHistory, LLMMessage{Role: r, Content: m.Content})
	}
	llmStart := time.Now()
	reply, err := s.llm.Chat(ctx, systemPrompt, llmHistory, childText)
	if err != nil {
		slog.ErrorContext(ctx, "LLM 调用失败", "child_id", childID,
			"err", err, "cost_ms", time.Since(llmStart).Milliseconds())
		return childText, "", fmt.Errorf("LLM 失败: %w", err)
	}
	slog.InfoContext(ctx, "LLM 回复完成", "child_id", childID,
		"reply_len", len(reply), "history_len", len(llmHistory),
		"cost_ms", time.Since(llmStart).Milliseconds())
	return childText, reply, nil
}
