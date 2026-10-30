package service

import (
	"context"
	"log/slog"
	"strings"

	"piggy-pal/server/internal/model"
)

// targetWordBonus 一轮里第一次说中今日目标词额外奖励的星星。
// 与 StarsForWords 的「1 词 1 颗、单轮最多 3 颗」叠加，单轮上限 5 颗。
const targetWordBonus = 2

// targetWordTurn 计算本轮结束后的目标词状态 + 额外星星。
// 必须在两条消息落库之前调用：planProgress 会把已落库的 child 消息算进去，
// 只有提前算才知道哪些词是「今天第一次说出」。
func (s *ChatService) targetWordTurn(ctx context.Context, childID, childText, replyText string) ([]model.TargetWord, int) {
	plan, ok := s.todayPlan(ctx, childID)
	if !ok || len(plan.Words) == 0 {
		return nil, 0
	}
	progress, err := s.planProgress(ctx, childID, plan.Date, plan.Date)
	if err != nil {
		slog.WarnContext(ctx, "读取目标词进度失败", "child_id", childID, "err", err)
	}
	p := progress[plan.Date]

	heard := map[string]bool{}
	said := map[string]bool{}
	if p != nil {
		for _, w := range p.HeardWords {
			heard[strings.ToLower(w)] = true
		}
		for _, w := range p.SaidWords {
			said[strings.ToLower(w)] = true
		}
	}
	// 角色这一轮的回复也算「听到」；宝宝这一轮的话还没落库，单独补进来。
	for _, w := range matchPlanWords(replyText, plan.Words) {
		heard[w] = true
	}
	justSaid := map[string]bool{}
	for _, w := range matchPlanWords(childText, plan.Words) {
		if !said[w] {
			justSaid[w] = true
		}
		said[w] = true
	}

	out := make([]model.TargetWord, 0, len(plan.Words))
	for _, w := range plan.Words {
		en := strings.ToLower(strings.TrimSpace(w.En))
		if en == "" {
			continue
		}
		out = append(out, model.TargetWord{
			En:       en,
			Zh:       w.Zh,
			Heard:    heard[en],
			Said:     said[en],
			JustSaid: justSaid[en],
		})
	}

	bonus := 0
	if len(justSaid) > 0 {
		bonus = targetWordBonus
	}
	return out, bonus
}

// recordWordLearning 把本轮目标词的 heard / said 累积到 word_learning，并安排复习日。
// 失败只记日志，不影响对话返回。
func (s *ChatService) recordWordLearning(ctx context.Context, childID, childText, replyText string) {
	plan, ok := s.todayPlan(ctx, childID)
	if !ok || len(plan.Words) == 0 {
		return
	}
	heard := matchPlanWords(replyText, plan.Words)
	said := matchPlanWords(childText, plan.Words)
	if len(heard) == 0 && len(said) == 0 {
		return
	}
	if err := s.store.RecordWordLearning(childID, plan.Date, plan.Words, heard, said); err != nil {
		slog.WarnContext(ctx, "记录单词掌握度失败", "child_id", childID, "err", err)
		return
	}
	slog.InfoContext(ctx, "记录单词掌握度", "child_id", childID,
		"heard", heard, "said", said)
}
