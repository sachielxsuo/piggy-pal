package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/store"
)

func todayPlanWord(t *testing.T, chat *ChatService, childID string) model.PlanDay {
	t.Helper()
	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, childID)
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	for _, d := range days {
		if d.Date == today && len(d.Words) > 0 {
			return d
		}
	}
	t.Fatal("今天没有计划词")
	return model.PlanDay{}
}

// 今天第一次说中目标词才有额外星星，同一天再说同一个词不再重复加。
func TestTargetWordTurnBonusOnlyFirstTime(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)
	ctx := context.Background()
	plan := todayPlanWord(t, chat, "anan")
	w := plan.Words[0]

	words, bonus := chat.targetWordTurn(ctx, "anan", "I see a "+w.En, "Yes, a "+w.En)
	if bonus != targetWordBonus {
		t.Fatalf("第一次说中应 +%d 颗，得到 %d", targetWordBonus, bonus)
	}
	found := false
	for _, tw := range words {
		if tw.En == w.En {
			found = true
			if !tw.JustSaid || !tw.Said {
				t.Fatalf("目标词状态不对: %+v", tw)
			}
		}
	}
	if !found {
		t.Fatalf("目标词状态里缺少 %s", w.En)
	}

	// 模拟这一轮落库
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "I see a " + w.En})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Yes, a " + w.En})

	_, bonus = chat.targetWordTurn(ctx, "anan", "I see a "+w.En, "Yes")
	if bonus != 0 {
		t.Fatalf("同一天重复说同一个词不应再加星，得到 %d", bonus)
	}

	// 同一天说中另一个新词，仍然有额外星星
	w2 := plan.Words[1]
	_, bonus = chat.targetWordTurn(ctx, "anan", w2.En, "Nice")
	if bonus != targetWordBonus {
		t.Fatalf("说中第二个新词应 +%d 颗，得到 %d", targetWordBonus, bonus)
	}
}

// 间隔重复：说过的词按掌握度安排复习日，到期后能被复习提示捞出来。
func TestRecordWordLearningSchedulesReview(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	words := []model.PlanWord{{En: "cat", Zh: "猫"}, {En: "dog", Zh: "狗"}}
	if err := st.RecordWordLearning("anan", "2026-10-01", words,
		[]string{"cat"}, []string{"cat", "dog"}); err != nil {
		t.Fatalf("记录掌握度失败: %v", err)
	}

	// 掌握度 1 → 2 天后复习，10-03 才到期
	if due, _ := st.DueReviewWords("anan", "2026-10-02", 3); len(due) != 0 {
		t.Fatalf("10-02 不该有到期词，得到 %d 个", len(due))
	}
	due, err := st.DueReviewWords("anan", "2026-10-03", 3)
	if err != nil {
		t.Fatalf("读取到期词失败: %v", err)
	}
	if len(due) != 2 {
		t.Fatalf("10-03 应有 2 个到期词，得到 %d", len(due))
	}

	toReview, mastered, err := st.WordLearningStats("anan", "2026-10-03")
	if err != nil {
		t.Fatalf("读取掌握度统计失败: %v", err)
	}
	if toReview != 2 || mastered != 0 {
		t.Fatalf("统计不对: toReview=%d mastered=%d", toReview, mastered)
	}

	// 再说 4 次 cat（累计 5 次）→ 掌握
	for i := 0; i < 4; i++ {
		date := time.Date(2026, 10, 3+i, 0, 0, 0, 0, time.Local).Format(dayLayout)
		if err := st.RecordWordLearning("anan", date, words, nil, []string{"cat"}); err != nil {
			t.Fatalf("第 %d 次记录失败: %v", i+2, err)
		}
	}
	_, mastered, err = st.WordLearningStats("anan", "2026-10-10")
	if err != nil {
		t.Fatalf("读取掌握度统计失败: %v", err)
	}
	if mastered != 1 {
		t.Fatalf("cat 说满 5 次应算掌握，mastered=%d", mastered)
	}
}

// 贴纸只按累计星星解锁，不消费星星。
func TestStickerBoardUnlocksByTotalStars(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)
	ctx := context.Background()

	if err := st.RecordActivity("anan", 30, 0, 0, 0); err != nil {
		t.Fatal(err)
	}
	board, err := chat.StickerBoard(ctx, "anan")
	if err != nil {
		t.Fatalf("读取贴纸墙失败: %v", err)
	}
	if board.TotalStars != 30 {
		t.Fatalf("累计星星应为 30，得到 %d", board.TotalStars)
	}
	if board.UnlockedCount() != 2 {
		t.Fatalf("30 颗应解锁 2 张（10/25），得到 %d", board.UnlockedCount())
	}
	if board.Next == nil || board.Next.Stars != 50 {
		t.Fatalf("下一张应是 50 颗门槛，得到 %+v", board.Next)
	}
}

// 睡前故事兜底模板必须带宝宝名字、目标词和中文晚安，不能只有英文。
func TestFallbackBedtimeStory(t *testing.T) {
	child := &model.Child{ChildID: "anan", Name: "安安", EnName: "Anan"}
	plan := model.PlanDay{Words: []model.PlanWord{{En: "moon", Zh: "月亮"}}}

	story := fallbackBedtimeStory(child, plan, true)
	if !strings.Contains(story, "Anan") {
		t.Fatalf("故事应叫宝宝英文名: %s", story)
	}
	if !strings.Contains(story, "moon") {
		t.Fatalf("故事应带入目标词: %s", story)
	}
	if !strings.Contains(story, "晚安") {
		t.Fatalf("故事应以中文晚安结尾: %s", story)
	}
}

// 模型只写英文时，也要补一句中文晚安。
func TestEnsureStoryGoodnight(t *testing.T) {
	child := &model.Child{EnName: "Anan"}
	got := ensureStoryGoodnight("Goodnight, baby. Sweet dreams.", child)
	if !strings.Contains(got, "晚安") || !strings.Contains(got, "Anan") {
		t.Fatalf("应补中文晚安: %q", got)
	}
	// 已经有中文就不要重复追加
	withCN := "Goodnight. 晚安，宝贝。"
	if got := ensureStoryGoodnight(withCN, child); got != withCN {
		t.Fatalf("已有中文不应改动: %q", got)
	}
}

func TestCleanStoryText(t *testing.T) {
	raw := "```\n故事：Goodnight, baby.\nThe moon is up.\n\nSweet dreams. 晚安。\n```"
	got := cleanStoryText(raw)
	if strings.Contains(got, "```") || strings.Contains(got, "故事：") {
		t.Fatalf("没清干净: %q", got)
	}
	if !strings.Contains(got, "Goodnight") || !strings.Contains(got, "晚安") {
		t.Fatalf("正文丢失: %q", got)
	}
}
