package store

import (
	"testing"
	"time"

	"piggy-pal/server/internal/model"
)

func samplePlanDays(start string, n int) []model.PlanDay {
	t, _ := time.Parse("2006-01-02", start)
	days := make([]model.PlanDay, 0, n)
	for i := 0; i < n; i++ {
		days = append(days, model.PlanDay{
			Date:     t.AddDate(0, 0, i).Format("2006-01-02"),
			DayIndex: i,
			Theme:    "动物朋友",
			Words: []model.PlanWord{
				{En: "cat", Zh: "猫"},
				{En: "dog", Zh: "狗"},
			},
		})
	}
	return days
}

func TestLearningPlanRoundTrip(t *testing.T) {
	s := newTestStore(t)
	days := samplePlanDays("2026-10-26", 7)
	if err := s.SaveLearningPlan("anan", "2026-10-26", "llm", days); err != nil {
		t.Fatalf("SaveLearningPlan: %v", err)
	}

	source, got, found, err := s.GetLearningPlanWeek("anan", "2026-10-26")
	if err != nil || !found {
		t.Fatalf("GetLearningPlanWeek: found=%v err=%v", found, err)
	}
	if source != "llm" {
		t.Fatalf("source 应为 llm，得到 %s", source)
	}
	if len(got) != 7 {
		t.Fatalf("应有 7 天，得到 %d", len(got))
	}
	if got[0].Words[0].En != "cat" || got[0].Words[0].Zh != "猫" {
		t.Fatalf("计划词解析不对: %+v", got[0].Words)
	}
	if got[6].Date != "2026-11-01" || got[6].DayIndex != 6 {
		t.Fatalf("第 7 天字段不对: %+v", got[6])
	}

	// 未生成的周
	_, _, found, err = s.GetLearningPlanWeek("anan", "2026-11-02")
	if err != nil || found {
		t.Fatalf("未生成的周应 found=false: found=%v err=%v", found, err)
	}
}

func TestLearningPlanDaysRangeAndPrevious(t *testing.T) {
	s := newTestStore(t)
	prev := samplePlanDays("2026-10-19", 7)
	cur := samplePlanDays("2026-10-26", 7)
	if err := s.SaveLearningPlan("anan", "2026-10-19", "fallback", prev); err != nil {
		t.Fatal(err)
	}
	if err := s.SaveLearningPlan("anan", "2026-10-26", "llm", cur); err != nil {
		t.Fatal(err)
	}

	got, err := s.GetLearningPlanDays("anan", "2026-10-25", "2026-10-27")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 {
		t.Fatalf("区间内应有 3 天，得到 %d", len(got))
	}

	words, err := s.PreviousWeekWords("anan", "2026-10-26")
	if err != nil {
		t.Fatal(err)
	}
	if len(words) != 14 {
		t.Fatalf("上周应有 14 个词，得到 %d", len(words))
	}
}

func TestMessagesBetween(t *testing.T) {
	s := newTestStore(t)
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai", Content: "Look, a cat"})
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child", Content: "cat"})
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "other", RoleID: "peppa", Speaker: "child", Content: "dog"})

	today := time.Now().Format("2006-01-02")
	msgs, err := s.MessagesBetween("anan", today, today)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("应只返回该宝宝今天的 2 条，得到 %d", len(msgs))
	}
	if msgs[0].Date != today || msgs[0].Speaker != "ai" || msgs[1].Speaker != "child" {
		t.Fatalf("消息字段不对: %+v", msgs)
	}
}
