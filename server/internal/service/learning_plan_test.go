package service

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/store"
)

func planJSON(days [][]model.PlanWord) string {
	type day struct {
		Theme string           `json:"theme"`
		Words []model.PlanWord `json:"words"`
	}
	payload := struct {
		Days []day `json:"days"`
	}{}
	for i, words := range days {
		payload.Days = append(payload.Days, day{Theme: fmt.Sprintf("主题%d", i+1), Words: words})
	}
	raw, _ := json.Marshal(payload)
	return string(raw)
}

func wordChunk(prefix string) []model.PlanWord {
	out := make([]model.PlanWord, 0, planWordsPerDay)
	for i := 0; i < planWordsPerDay; i++ {
		out = append(out, model.PlanWord{En: prefix + string(rune('a'+i)), Zh: "词"})
	}
	return out
}

func TestParsePlanDaysValid(t *testing.T) {
	days := make([][]model.PlanWord, 0, 7)
	days = append(days, wordChunk("aa"))
	days = append(days, wordChunk("bb"))
	days = append(days, wordChunk("cc"))
	days = append(days, wordChunk("dd"))
	days = append(days, wordChunk("ee"))
	days = append(days, wordChunk("ff"))
	// 周日：从前面各主题挑词复习
	review := []model.PlanWord{
		days[0][0], days[0][1],
		days[2][0], days[2][1],
		days[4][0],
	}
	days = append(days, review)

	got, err := parsePlanDays(planJSON(days), "2026-10-26")
	if err != nil {
		t.Fatalf("合法计划不应报错: %v", err)
	}
	if len(got) != 7 {
		t.Fatalf("应返回 7 天，得到 %d", len(got))
	}
	if got[0].Date != "2026-10-26" || got[6].Date != "2026-11-01" {
		t.Fatalf("日期递进不对: %s ~ %s", got[0].Date, got[6].Date)
	}
	if len(got[0].Words) != planWordsPerDay {
		t.Fatalf("每天应 %d 个词，得到 %d", planWordsPerDay, len(got[0].Words))
	}
}

func TestParsePlanDaysRejects(t *testing.T) {
	valid := func() [][]model.PlanWord {
		return [][]model.PlanWord{
			wordChunk("aa"), wordChunk("bb"), wordChunk("cc"), wordChunk("dd"),
			wordChunk("ee"), wordChunk("ff"), wordChunk("aa"),
		}
	}

	t.Run("天数不足", func(t *testing.T) {
		if _, err := parsePlanDays(planJSON(valid()[:6]), "2026-10-26"); err == nil {
			t.Fatal("少于 7 天应报错")
		}
	})

	t.Run("单词带空格", func(t *testing.T) {
		days := valid()
		days[0][0] = model.PlanWord{En: "ice cream", Zh: "冰淇淋"}
		if _, err := parsePlanDays(planJSON(days), "2026-10-26"); err == nil {
			t.Fatal("多词应报错")
		}
	})

	t.Run("大写或非法字符", func(t *testing.T) {
		days := valid()
		days[0][0] = model.PlanWord{En: "Cat", Zh: "猫"}
		if _, err := parsePlanDays(planJSON(days), "2026-10-26"); err == nil {
			t.Fatal("大写应报错")
		}
	})

	t.Run("周内重复超过两次", func(t *testing.T) {
		days := valid()
		days[1][0] = days[0][0]
		days[3][0] = days[0][0]
		if _, err := parsePlanDays(planJSON(days), "2026-10-26"); err == nil {
			t.Fatal("同一个词一周出现 3 次应报错")
		}
	})

	t.Run("允许间隔复习", func(t *testing.T) {
		days := valid()
		days[2][0] = days[0][0]
		if _, err := parsePlanDays(planJSON(days), "2026-10-26"); err != nil {
			t.Fatalf("同一个词间隔出现两次应允许: %v", err)
		}
	})

	t.Run("周日出现新词", func(t *testing.T) {
		days := valid()
		days[6][0] = model.PlanWord{En: "zebra", Zh: "斑马"}
		if _, err := parsePlanDays(planJSON(days), "2026-10-26"); err == nil {
			t.Fatal("周日出现本周没学过的词应报错")
		}
	})
}

func TestMatchPlanWords(t *testing.T) {
	words := []model.PlanWord{{En: "cat", Zh: "猫"}, {En: "bus", Zh: "巴士"}, {En: "apple", Zh: "苹果"}}
	cases := []struct {
		text string
		want int
	}{
		{"Look, a cat!", 1},
		{"I see cats and a bus", 2},
		{"APPLE, apple, apples", 1},
		{"dog and pig", 0},
		{"", 0},
	}
	for _, c := range cases {
		if got := matchPlanWords(c.text, words); len(got) != c.want {
			t.Errorf("matchPlanWords(%q) = %v, 期望 %d 个", c.text, got, c.want)
		}
	}
}

func TestFallbackPlanShape(t *testing.T) {
	days := fallbackPlan("2026-10-26")
	if len(days) != 7 {
		t.Fatalf("应 7 天，得到 %d", len(days))
	}
	seen := map[string]bool{}
	for i, d := range days {
		if len(d.Words) != planWordsPerDay {
			t.Fatalf("第 %d 天应 %d 个词，得到 %d", i+1, planWordsPerDay, len(d.Words))
		}
		if d.Theme == "" {
			t.Fatalf("第 %d 天缺主题", i+1)
		}
		if i == 6 {
			for _, w := range d.Words {
				if !seen[w.En] {
					t.Fatalf("复习日出现新词 %s", w.En)
				}
			}
			continue
		}
		for _, w := range d.Words {
			if !planWordRE.MatchString(w.En) {
				t.Fatalf("兜底词不合法: %q", w.En)
			}
			if seen[w.En] {
				t.Fatalf("兜底计划周内重复: %s", w.En)
			}
			seen[w.En] = true
		}
	}
	if !strings.HasPrefix(days[0].Date, "2026-10-26") || days[6].Date != "2026-11-01" {
		t.Fatalf("兜底计划日期不对: %s ~ %s", days[0].Date, days[6].Date)
	}
}

func TestEnsureWeekPlanIsIdempotent(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	start1, _, days1, err := chat.EnsureWeekPlan(context.Background(), "anan")
	if err != nil {
		t.Fatalf("首次生成失败: %v", err)
	}
	start2, _, days2, err := chat.EnsureWeekPlan(context.Background(), "anan")
	if err != nil {
		t.Fatalf("二次读取失败: %v", err)
	}
	if start1 != start2 || len(days1) != len(days2) {
		t.Fatal("同一周应返回同一份计划")
	}
	if days1[0].Words[0].En != days2[0].Words[0].En {
		t.Fatal("重复调用不应重新生成计划")
	}
}

func TestLearningHintAndProgress(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	if len(plan.Words) == 0 {
		t.Fatal("今天没有计划词")
	}

	hint := chat.learningHint(ctx, "anan", "peppa", "")
	if !strings.Contains(hint, "【今日对话主线】") {
		t.Fatalf("提示词缺少主线段落: %s", hint)
	}
	if !strings.Contains(hint, plan.Words[0].En) {
		t.Fatalf("提示词缺少目标词 %s", plan.Words[0].En)
	}

	w := plan.Words[0]
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look! A " + w.En + "!"})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "It is a " + w.En})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "xylophone"})

	progress, err := chat.PlanProgress(ctx, "anan", today, today)
	if err != nil {
		t.Fatalf("统计失败: %v", err)
	}
	p := progress[today]
	if p == nil {
		t.Fatal("今天应有计划进度")
	}
	if p.Heard != 1 || p.Said != 1 {
		t.Fatalf("应听到 1 个、说出 1 个，得到 heard=%d said=%d", p.Heard, p.Said)
	}
	if len(p.HeardWords) != 1 || p.HeardWords[0] != w.En {
		t.Fatalf("听到的词不对: %v", p.HeardWords)
	}
}

func TestOffTopicStreak(t *testing.T) {
	words := []model.PlanWord{{En: "cat", Zh: "猫"}, {En: "dog", Zh: "狗"}}
	msgs := []model.DatedMessage{
		{Speaker: "child", Content: "cat"},
		{Speaker: "ai", Content: "Yes, a cat!"},
		{Speaker: "child", Content: "I like cars"},
		{Speaker: "ai", Content: "Cars are fast."},
		{Speaker: "child", Content: "vroom vroom"},
	}
	if got := offTopicStreak(msgs, words); got != 2 {
		t.Fatalf("连续跑题应为 2 轮，得到 %d", got)
	}

	// 简短回应不算跑题；当天角色还没说过计划词时也不计
	if got := offTopicStreak([]model.DatedMessage{
		{Speaker: "ai", Content: "Hello!"},
		{Speaker: "child", Content: "I like cars"},
	}, words); got != 0 {
		t.Fatalf("还没引入计划词时不应算跑题，得到 %d", got)
	}
	if got := offTopicStreak([]model.DatedMessage{
		{Speaker: "ai", Content: "Look, a cat!"},
		{Speaker: "child", Content: "yes"},
	}, words); got != 0 {
		t.Fatalf("简短回应不应算跑题，得到 %d", got)
	}
	// 情绪表达不算跑题：那是该停下来的信号，不该累加成「必须拉回主线」的压力
	if got := offTopicStreak([]model.DatedMessage{
		{Speaker: "ai", Content: "Look, a cat!"},
		{Speaker: "child", Content: "我不喜欢这样，我不想玩了"},
	}, words); got != 0 {
		t.Fatalf("情绪表达不应算跑题，得到 %d", got)
	}

	// 宝宝刚说回目标词：连续轮数清零
	msgs = append(msgs, model.DatedMessage{Speaker: "child", Content: "dog"})
	if got := offTopicStreak(msgs, words); got != 0 {
		t.Fatalf("说到目标词后应清零，得到 %d", got)
	}
}

func TestLearningHintBridgesBackAfterOffTopic(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	if len(plan.Words) == 0 {
		t.Fatal("今天没有计划词")
	}
	w := plan.Words[0]

	// 第 1 轮：宝宝在主线内
	hint := chat.learningHint(ctx, "anan", "peppa", "hello")
	if !strings.Contains(hint, plan.Theme) || !strings.Contains(hint, "保持主线") {
		t.Fatalf("主线内提示不对:\n%s", hint)
	}

	// 角色说了一个词，宝宝接着跑题
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look, a " + w.En + "!"})
	hint = chat.learningHint(ctx, "anan", "peppa", "I like cars")
	if !strings.Contains(hint, "角色说过、宝宝还没说") {
		t.Fatalf("缺少「已出现未说」状态:\n%s", hint)
	}
	if !strings.Contains(hint, "可以带回主线") {
		t.Fatalf("跑题 1 轮应提示可以带回主线:\n%s", hint)
	}

	// 连续第 2 轮跑题：必须强行桥接
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "I like cars"})
	hint = chat.learningHint(ctx, "anan", "peppa", "vroom vroom")
	if !strings.Contains(hint, "先跟一会儿") || !strings.Contains(hint, "连续 2 轮") {
		t.Fatalf("连续跑题 2 轮应提示先陪玩、不硬拐:\n%s", hint)
	}

	// 宝宝这一轮说回目标词：状态变成已说，并回到主线
	hint = chat.learningHint(ctx, "anan", "peppa", "It is a "+w.En)
	if !strings.Contains(hint, "宝宝已经说过") {
		t.Fatalf("缺少「宝宝已说」状态:\n%s", hint)
	}
	if strings.Contains(hint, "可以带回主线") || strings.Contains(hint, "先跟一会儿") {
		t.Fatalf("宝宝说回目标词后不应再提示拉回:\n%s", hint)
	}

	// 落库后进度里的连续轮数也应清零
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "It is a " + w.En})
	progress, err := chat.PlanProgress(ctx, "anan", today, today)
	if err != nil || progress[today] == nil {
		t.Fatalf("读取进度失败: %v", err)
	}
	if got := progress[today].TurnsSincePlanWord; got != 0 {
		t.Fatalf("说到目标词后连续轮数应清零，得到 %d", got)
	}
}

func TestGreetingPlanHint(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatal(err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}

	hint := chat.greetingPlanHint(ctx, "anan")
	if !strings.Contains(hint, plan.Theme) || !strings.Contains(hint, plan.Words[0].En) {
		t.Fatalf("开场提示应包含主题和首个未出现词:\n%s", hint)
	}
	// 开场提示不应塞入整段对话规则
	if strings.Contains(hint, "引导规则") {
		t.Fatalf("开场提示不应包含完整规则:\n%s", hint)
	}
}

func TestDetectChildMood(t *testing.T) {
	cases := []struct {
		text string
		want childMood
	}{
		// 真实对话里出现过的原话
		{"我不喜欢你干啥总是记不住", moodUpset},
		{"我都不想跟你玩了", moodLeave},
		{"说了我不喜欢玩恐龙", moodUpset},
		{"喜欢，我想跟佩奇姥姥再见", moodLeave},
		{"你昨天不理我啦，还是不会说话啦？", moodUpset},
		{"我数1234512345，这个好，你英文啊？", moodNeutral},
		{"One.", moodNeutral},
		{"1234567.", moodNeutral},
		{"我喜欢苹果", moodNeutral},
		// A 不 A 的疑问句不是拒绝
		{"我们要不要出去玩", moodNeutral},
		{"你想不想玩恐龙", moodNeutral},
		{"你喜欢不喜欢pear", moodNeutral},
		{"", moodNeutral},
	}
	for _, tc := range cases {
		if got := detectChildMood(tc.text); got != tc.want {
			t.Errorf("detectChildMood(%q) = %v, want %v", tc.text, got, tc.want)
		}
	}
}

// 情绪优先：宝宝说「不喜欢 / 不想玩」时，当轮不能再出现任何目标词和英语问题。
func TestLearningHintEmotionFirst(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	if len(plan.Words) == 0 {
		t.Fatal("今天没有计划词")
	}
	// 角色刚刚追问过目标词
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Do you like " + plan.Words[0].En + "?"})

	hint := chat.learningHint(ctx, "anan", "peppa", "我不喜欢你干啥总是记不住")
	if !strings.Contains(hint, "先照顾情绪") {
		t.Fatalf("应切换到情绪优先:\n%s", hint)
	}
	if strings.Contains(hint, "引导规则") {
		t.Fatalf("情绪轮不应再注入教学规则:\n%s", hint)
	}
	for _, w := range plan.Words {
		if strings.Contains(strings.ToLower(hint), strings.ToLower(w.En)) {
			t.Fatalf("情绪轮不应出现目标词 %s:\n%s", w.En, hint)
		}
	}
}

func TestLearningHintRespectsGoodbye(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	if _, _, _, err := chat.EnsureWeekPlan(ctx, "anan"); err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}

	hint := chat.learningHint(ctx, "anan", "peppa", "我不想玩了，再见")
	if !strings.Contains(hint, "宝宝想结束") {
		t.Fatalf("道别应走「尊重离开」分支:\n%s", hint)
	}
	if strings.Contains(hint, "引导规则") || strings.Contains(hint, "可以自然带出") {
		t.Fatalf("道别轮不应再教学:\n%s", hint)
	}
}

// 上一轮刚问过、宝宝没接的词，这一轮不能再问，也不能进「可以自然带出」。
func TestLearningHintSuppressesJustAskedWord(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	w := plan.Words[0]

	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look! A " + w.En + ". Do you like it?"})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "我不喜欢玩恐龙"})

	hint := chat.learningHint(ctx, "anan", "peppa", "我想说别的")
	if !strings.Contains(hint, "不要再提") || !strings.Contains(hint, "上一轮刚问过") {
		t.Fatalf("刚问过的词应被压住:\n%s", hint)
	}
	for _, line := range strings.Split(hint, "\n") {
		if strings.HasPrefix(line, "- 这一轮可以自然带出") && strings.Contains(line, w.En) {
			t.Fatalf("刚问过的词不应再出现在可引导列表: %s", line)
		}
	}
}

// 连着两轮问同一个词：必须升级成「绝对不要再提」。
func TestLearningHintSuppressesTwiceAskedWord(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	w := plan.Words[0]

	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look, a " + w.En + "!"})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "我在数数"})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Do you like " + w.En + "?"})

	hint := chat.learningHint(ctx, "anan", "peppa", "我在数数")
	if !strings.Contains(hint, "连着两轮追问") {
		t.Fatalf("连续追问同一个词应升级提示:\n%s", hint)
	}
}

// 宝宝已经说过的词不受抑制影响（复现巩固是正常的）。
func TestLearningHintAllowsSaidWordRevisit(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	ctx := context.Background()
	_, _, days, err := chat.EnsureWeekPlan(ctx, "anan")
	if err != nil {
		t.Fatalf("生成计划失败: %v", err)
	}
	today := time.Now().Format(dayLayout)
	var plan model.PlanDay
	for _, d := range days {
		if d.Date == today {
			plan = d
		}
	}
	w := plan.Words[0]

	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look, a " + w.En + "!"})
	_ = st.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child",
		Content: "It is a " + w.En})

	hint := chat.learningHint(ctx, "anan", "peppa", "I like it")
	if strings.Contains(hint, "不要再提") {
		t.Fatalf("宝宝已经说过的词不该被压住:\n%s", hint)
	}
	if !strings.Contains(hint, "宝宝已经说过") {
		t.Fatalf("应提示宝宝已经说过:\n%s", hint)
	}
}

// 称呼一致性：中文句用中文名，英文句用英文名，不能混着叫。
func TestChildIdentityNameConsistency(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	child := &model.Child{ChildID: "c1", Name: "小雨", EnName: "Rain", Age: 5}
	prompt := chat.buildSystemPrompt(&config.Role{RoleID: "peppa", Name: "佩奇"}, child)
	if !strings.Contains(prompt, "称呼规则") {
		t.Fatalf("缺少称呼规则:\n%s", prompt)
	}
	if !strings.Contains(prompt, "小雨") || !strings.Contains(prompt, "Rain") {
		t.Fatalf("应同时给出中英文名:\n%s", prompt)
	}
	if !strings.Contains(prompt, "不要在同一句里中英文名混着叫") {
		t.Fatalf("缺少混用约束:\n%s", prompt)
	}
}
