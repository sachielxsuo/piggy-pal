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

// bedtimeStorySentences 故事控制在 4-6 句，读完约 1 分钟，适合睡前。
const bedtimeStorySentences = 6

// BedtimeStory 返回今天的睡前故事：每天每个角色第一次调用时生成并落库，当天复用。
// slow=true 时用 0.75 倍语速合成，睡前听更轻柔。
func (s *ChatService) BedtimeStory(ctx context.Context, childID, roleID string, slow bool) (*model.BedtimeStoryResponse, error) {
	role := s.findRole(roleID)
	if role == nil {
		return nil, ErrRoleNotFound
	}
	date := time.Now().Format(dayLayout)
	resp := &model.BedtimeStoryResponse{
		ChildID: childID, RoleID: roleID, Date: date, AudioFormat: "mp3",
	}

	text, found, err := s.store.GetBedtimeStory(childID, roleID, date)
	if err != nil {
		slog.WarnContext(ctx, "读取睡前故事失败，按未生成处理",
			"child_id", childID, "role_id", roleID, "err", err)
	}
	if found && strings.TrimSpace(text) != "" {
		text = strings.TrimSpace(text)
	} else {
		child, _ := s.store.GetChild(childID)
		text = s.generateBedtimeStory(ctx, childID, role, child)
		if err := s.store.SaveBedtimeStory(childID, roleID, date, text); err != nil {
			slog.WarnContext(ctx, "保存睡前故事失败",
				"child_id", childID, "role_id", roleID, "err", err)
		} else {
			resp.IsNew = true
		}
		slog.InfoContext(ctx, "睡前故事生成完成",
			"child_id", childID, "role_id", roleID, "text_len", len([]rune(text)))
	}
	resp.Text = text

	if s.tts != nil && s.tts.Enabled() {
		ttsText := strings.ReplaceAll(text, "\n", " ")
		factor := 1.0
		if slow {
			factor = slowSpeedFactor
		}
		if audio, err := s.synthesizeRoleAtSpeed(role, ttsText, factor); err == nil {
			resp.AudioB64 = audio
		} else {
			slog.WarnContext(ctx, "睡前故事 TTS 合成失败，降级纯文本",
				"role_id", roleID, "slow", slow, "err", err)
		}
	}
	return resp, nil
}

// generateBedtimeStory 用 LLM 写一段 4-6 句的简单英文故事 + 中文晚安；失败走固定模板。
func (s *ChatService) generateBedtimeStory(ctx context.Context, childID string, role *config.Role, child *model.Child) string {
	plan, hasPlan := s.todayPlan(ctx, childID)
	if s.llm != nil && s.llm.Enabled() {
		prompt := buildBedtimeStoryPrompt(role, child, plan, hasPlan)
		for attempt := 0; attempt < 2; attempt++ {
			raw, err := s.llm.Chat(ctx, prompt, nil, "请写今晚的睡前小故事。")
			if err != nil {
				slog.WarnContext(ctx, "睡前故事 LLM 调用失败，使用兜底故事",
					"role_id", role.RoleID, "err", err)
				break
			}
			story := cleanStoryText(raw)
			if story == "" {
				break
			}
			if s.guard != nil && s.guard.ContainsBlocked(story) {
				slog.WarnContext(ctx, "睡前故事命中护栏，使用兜底故事", "role_id", role.RoleID)
				break
			}
			if englishWordCount(story) < 12 {
				slog.WarnContext(ctx, "睡前故事英文太少，重试", "role_id", role.RoleID)
				prompt += "\n注意：上一次英文太少。必须至少 4 句完整英文，每句 3-7 个单词。"
				continue
			}
			return ensureStoryGoodnight(story, child)
		}
	}
	return fallbackBedtimeStory(child, plan, hasPlan)
}

// ensureStoryGoodnight 保证故事最后一定有一句中文晚安。
// 模型偶尔只写英文，这里兜一层，睡前仪式感不能丢。
func ensureStoryGoodnight(story string, child *model.Child) string {
	if hasChinese(story) {
		return story
	}
	return story + "\n晚安，" + storyChildName(child) + "，做个甜甜的梦。"
}

// storyChildName 取宝宝英文名优先，其次中文名，最后「宝宝」。
func storyChildName(child *model.Child) string {
	if child != nil {
		if en := strings.TrimSpace(child.EnName); en != "" {
			return en
		}
		if cn := strings.TrimSpace(child.Name); cn != "" {
			return cn
		}
	}
	return "宝宝"
}

// buildBedtimeStoryPrompt 组装睡前故事提示词：简单、温柔、带今天的目标词。
func buildBedtimeStoryPrompt(role *config.Role, child *model.Child, plan model.PlanDay, hasPlan bool) string {
	parts := []string{
		"你在给一个 3-6 岁的中国宝宝写睡前小故事。",
	}
	if role != nil {
		parts = append(parts, fmt.Sprintf("讲故事的角色：%s（%s）。角色设定：%s", role.Name, role.En, role.Persona))
	}
	if id := childIdentity(child); id != "" {
		parts = append(parts, id)
	}
	parts = append(parts,
		"要求：\n"+
			"- 4-6 句英文，每句 3-7 个单词，只用最基础的词（动物、颜色、食物、动作、家人）\n"+
			"- 句子短、节奏慢、温柔，适合睡前听；不要出现怪物、打斗、巨响、危险情节\n"+
			"- 用宝宝的名字开头打招呼，最后用一句中文说晚安（例如「晚安，做个甜甜的梦。」）\n"+
			"- 全文不超过 70 个英文单词，不要标题、编号、解释、表情符号\n"+
			"- 只输出故事正文，不要 markdown 代码块")
	if hasPlan && len(plan.Words) > 0 {
		words := make([]string, 0, 3)
		for i, w := range plan.Words {
			if i >= 3 {
				break
			}
			words = append(words, w.En+"（"+w.Zh+"）")
		}
		parts = append(parts, "自然带入今天学过的 2-3 个词："+strings.Join(words, "、")+"，每个词只出现一次。")
	}
	return strings.Join(parts, "\n")
}

// cleanStoryText 清理模型输出：去代码块 / 标题 / 引号，保留换行，限制长度。
func cleanStoryText(raw string) string {
	text := strings.TrimSpace(raw)
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	text = strings.Trim(text, "`\"'“”‘’「」")

	lines := make([]string, 0, 8)
	for _, line := range strings.Split(text, "\n") {
		l := strings.TrimSpace(line)
		if l == "" {
			continue
		}
		// 去掉「故事：」「Story:」这类前缀和列表符号
		l = strings.Trim(l, "-•*· ")
		l = trimLabelPrefix(l, "故事", "Story", "睡前故事")
		if l == "" || strings.HasPrefix(l, "```") {
			continue
		}
		lines = append(lines, l)
		if len(lines) >= bedtimeStorySentences+2 {
			break
		}
	}
	return truncateRunes(strings.Join(lines, "\n"), 600)
}

// fallbackBedtimeStory LLM 不可用时的固定睡前故事，带入 1-2 个今日目标词。
func fallbackBedtimeStory(child *model.Child, plan model.PlanDay, hasPlan bool) string {
	name := storyChildName(child)
	word := "moon"
	if hasPlan && len(plan.Words) > 0 {
		word = plan.Words[0].En
	}
	return fmt.Sprintf(
		"Goodnight, %s. The moon is up. The stars are shining.\n"+
			"Little %s is sleepy too. Close your eyes, my dear.\n"+
			"Sweet dreams. 晚安，%s，做个甜甜的梦。",
		name, word, name,
	)
}
