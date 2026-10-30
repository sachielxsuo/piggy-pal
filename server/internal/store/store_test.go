package store

import (
	"testing"

	"piggy-pal/server/internal/model"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatalf("打开测试库失败: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestUpsertAndGetChild(t *testing.T) {
	s := newTestStore(t)

	// 创建
	c := &model.Child{ChildID: "anan", FamilyID: "default", Name: "安安", Age: 4, Gender: "女"}
	if err := s.UpsertChild(c); err != nil {
		t.Fatalf("UpsertChild: %v", err)
	}
	got, err := s.GetChild("anan")
	if err != nil {
		t.Fatalf("GetChild: %v", err)
	}
	if got == nil {
		t.Fatal("GetChild 返回 nil")
	}
	if got.Name != "安安" || got.Age != 4 || got.Gender != "女" {
		t.Fatalf("字段不符: %+v", got)
	}

	// 更新（同 child_id 覆盖）
	if err := s.UpsertChild(&model.Child{ChildID: "anan", Name: "安安", Age: 5}); err != nil {
		t.Fatalf("更新 UpsertChild: %v", err)
	}
	got2, _ := s.GetChild("anan")
	if got2.Age != 5 {
		t.Fatalf("更新后年龄应为 5，得到 %d", got2.Age)
	}
}

func TestGetChildNotFound(t *testing.T) {
	s := newTestStore(t)
	got, err := s.GetChild("nobody")
	if err != nil {
		t.Fatalf("GetChild: %v", err)
	}
	if got != nil {
		t.Fatalf("不存在的宝宝应返回 nil，得到 %+v", got)
	}
}

func TestListChildren(t *testing.T) {
	s := newTestStore(t)
	_ = s.UpsertChild(&model.Child{ChildID: "a", Name: "A"})
	_ = s.UpsertChild(&model.Child{ChildID: "b", Name: "B"})

	list, err := s.ListChildren()
	if err != nil {
		t.Fatalf("ListChildren: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("期望 2 个宝宝，得到 %d", len(list))
	}
}

func TestMessagesIsolationAndOrder(t *testing.T) {
	s := newTestStore(t)

	// anan + peppa：2 条
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child", Content: "hi"})
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai", Content: "hello"})
	// anan + george：1 条（应被隔离）
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "george", Speaker: "child", Content: "dino"})
	// bob + peppa：1 条（应被隔离）
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "bob", RoleID: "peppa", Speaker: "child", Content: "hi bob"})

	msgs, err := s.RecentMessages("anan", "peppa", 10)
	if err != nil {
		t.Fatalf("RecentMessages: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("期望 2 条，得到 %d", len(msgs))
	}
	if msgs[0].Content != "hi" || msgs[1].Content != "hello" {
		t.Fatalf("顺序应为正序 [hi, hello]，得到 %+v", msgs)
	}

	// limit 生效：取最近 1 条应为最后一条
	limited, _ := s.RecentMessages("anan", "peppa", 1)
	if len(limited) != 1 || limited[0].Content != "hello" {
		t.Fatalf("limit=1 应返回最近 1 条 hello，得到 %+v", limited)
	}
}

func TestRecordActivityAndStats(t *testing.T) {
	s := newTestStore(t)

	// 两次对话的星星 / 词数 + 一次会话时长
	_ = s.RecordActivity("anan", 1, 2, 0, 0)
	_ = s.RecordActivity("anan", 1, 3, 0, 0)
	_ = s.RecordActivity("anan", 0, 0, 120, 1)
	_ = s.SaveMessage(&model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "child", Content: "hello"})

	stats, err := s.GetChildStats("anan")
	if err != nil {
		t.Fatalf("GetChildStats: %v", err)
	}
	if stats.Today.Stars != 2 || stats.Today.WordCount != 5 {
		t.Fatalf("今日星星/词数不符: %+v", stats.Today)
	}
	if stats.Today.DurationSec != 120 || stats.Today.OpenCount != 1 {
		t.Fatalf("今日时长/打开次数不符: %+v", stats.Today)
	}
	if stats.Today.Utterances != 1 || stats.TotalUtterances != 1 {
		t.Fatalf("开口次数不符: today=%d total=%d", stats.Today.Utterances, stats.TotalUtterances)
	}
	if stats.Total.Stars != 2 || stats.Total.WordCount != 5 || stats.Total.DurationSec != 120 {
		t.Fatalf("累计统计不符: %+v", stats.Total)
	}
	if stats.WeekStars != 2 || stats.StreakDays != 1 {
		t.Fatalf("本周星星/连续天数不符: week=%d streak=%d", stats.WeekStars, stats.StreakDays)
	}
	if len(stats.Week) != 7 {
		t.Fatalf("最近 7 天应返回 7 条，得到 %d", len(stats.Week))
	}
	if stats.Week[6].Date != stats.Today.Date {
		t.Fatalf("最后一条应为今天: %+v", stats.Week[6])
	}

	// 全零上报不产生记录
	_ = s.RecordActivity("bob", 0, 0, 0, 0)
	empty, err := s.GetChildStats("bob")
	if err != nil {
		t.Fatalf("GetChildStats(bob): %v", err)
	}
	if empty.Today.Stars != 0 || empty.StreakDays != 0 || empty.Total.OpenCount != 0 {
		t.Fatalf("全零上报不应产生统计: %+v", empty)
	}
}

func TestSessionStarsAndSync(t *testing.T) {
	s := newTestStore(t)

	if got, err := s.RecordChatActivity("anan", "sess-1", 2, 2); err != nil || got != 2 {
		t.Fatalf("第一轮会话星星应为 2，得到 %d (err=%v)", got, err)
	}
	if got, err := s.RecordChatActivity("anan", "sess-1", 3, 5); err != nil || got != 5 {
		t.Fatalf("第二轮会话星星应为 5，得到 %d (err=%v)", got, err)
	}
	stats, _ := s.GetChildStats("anan")
	if stats.Today.Stars != 5 || stats.Today.WordCount != 7 {
		t.Fatalf("当天统计不符: %+v", stats.Today)
	}

	// 重复 / 落后的快照不重复加星
	if got, err := s.SyncSession("anan", "sess-1", 3); err != nil || got != 5 {
		t.Fatalf("落后快照应保持 5，得到 %d (err=%v)", got, err)
	}
	stats, _ = s.GetChildStats("anan")
	if stats.Today.Stars != 5 {
		t.Fatalf("落后快照不应加星，得到 %d", stats.Today.Stars)
	}

	// 更新的快照只补差额
	if got, err := s.SyncSession("anan", "sess-1", 8); err != nil || got != 8 {
		t.Fatalf("快照应补到 8，得到 %d (err=%v)", got, err)
	}
	stats, _ = s.GetChildStats("anan")
	if stats.Today.Stars != 8 {
		t.Fatalf("补差额后当天星星应为 8，得到 %d", stats.Today.Stars)
	}

	// 未知会话只建档，不重复补当天统计
	if got, err := s.SyncSession("anan", "sess-unknown", 4); err != nil || got != 4 {
		t.Fatalf("未知会话快照应返回 4，得到 %d (err=%v)", got, err)
	}
	stats, _ = s.GetChildStats("anan")
	if stats.Today.Stars != 8 {
		t.Fatalf("未知会话不应改当天统计，得到 %d", stats.Today.Stars)
	}

	if got, err := s.GetSessionStars("anan", "sess-1"); err != nil || got != 8 {
		t.Fatalf("GetSessionStars 应为 8，得到 %d (err=%v)", got, err)
	}
	if got, err := s.GetSessionStars("anan", "nope"); err != nil || got != 0 {
		t.Fatalf("未知会话星星应为 0，得到 %d (err=%v)", got, err)
	}
}

func TestPIN(t *testing.T) {
	s := newTestStore(t)

	// 初始无 PIN
	h, err := s.GetPIN("default")
	if err != nil {
		t.Fatalf("GetPIN: %v", err)
	}
	if h != "" {
		t.Fatalf("初始 PIN 应为空，得到 %q", h)
	}

	// 设置
	if err := s.SetPIN("default", "hashed"); err != nil {
		t.Fatalf("SetPIN: %v", err)
	}
	h, _ = s.GetPIN("default")
	if h != "hashed" {
		t.Fatalf("PIN 应为 hashed，得到 %q", h)
	}

	// 更新
	_ = s.SetPIN("default", "hashed2")
	h, _ = s.GetPIN("default")
	if h != "hashed2" {
		t.Fatalf("更新后 PIN 应为 hashed2，得到 %q", h)
	}
}

func TestDailyGreeting(t *testing.T) {
	s := newTestStore(t)

	// 没生成过
	if _, ok, err := s.GetDailyGreeting("anan", "peppa", "2026-10-25"); err != nil || ok {
		t.Fatalf("未生成时应返回 ok=false，err=%v ok=%v", err, ok)
	}

	// 首次保存
	if err := s.SaveDailyGreeting("anan", "peppa", "2026-10-25", "今天聊 animals 吧"); err != nil {
		t.Fatalf("SaveDailyGreeting: %v", err)
	}
	got, ok, err := s.GetDailyGreeting("anan", "peppa", "2026-10-25")
	if err != nil || !ok || got != "今天聊 animals 吧" {
		t.Fatalf("读取今日话题失败: got=%q ok=%v err=%v", got, ok, err)
	}

	// 同一天重复写入应被忽略（幂等，保证「每天首次生成」）
	if err := s.SaveDailyGreeting("anan", "peppa", "2026-10-25", "另一个话题"); err != nil {
		t.Fatalf("重复 SaveDailyGreeting: %v", err)
	}
	if got, _, _ := s.GetDailyGreeting("anan", "peppa", "2026-10-25"); got != "今天聊 animals 吧" {
		t.Fatalf("同一天不应覆盖，得到 %q", got)
	}

	// 历史话题按日期倒序，且不含当天
	_ = s.SaveDailyGreeting("anan", "peppa", "2026-10-23", "聊 colors")
	_ = s.SaveDailyGreeting("anan", "peppa", "2026-10-24", "聊 food")
	recent, err := s.RecentDailyGreetingTexts("anan", "peppa", "2026-10-25", 5)
	if err != nil {
		t.Fatalf("RecentDailyGreetingTexts: %v", err)
	}
	if len(recent) != 2 || recent[0] != "聊 food" || recent[1] != "聊 colors" {
		t.Fatalf("历史话题应为 [聊 food 聊 colors]，得到 %v", recent)
	}

	// 角色 / 宝宝隔离
	if _, ok, _ := s.GetDailyGreeting("anan", "george", "2026-10-25"); ok {
		t.Fatal("不同角色不应共享今日话题")
	}
}

func TestMessagesPage(t *testing.T) {
	s := newTestStore(t)
	for i := 1; i <= 5; i++ {
		_ = s.SaveMessage(&model.ChatMessage{
			ChildID: "anan", RoleID: "peppa", Speaker: "child", Content: "m" + string(rune('0'+i)),
		})
	}

	// 最新一页：m4 m5，还有更早的
	msgs, hasMore, err := s.MessagesPage("anan", "peppa", 0, 2)
	if err != nil {
		t.Fatalf("MessagesPage: %v", err)
	}
	if len(msgs) != 2 || msgs[0].Content != "m4" || msgs[1].Content != "m5" || !hasMore {
		t.Fatalf("最新一页应返回 [m4 m5] 且 hasMore=true，得到 %+v hasMore=%v", msgs, hasMore)
	}

	// 上滑加载更早一页：m2 m3
	older, hasMore, err := s.MessagesPage("anan", "peppa", msgs[0].ID, 2)
	if err != nil {
		t.Fatalf("MessagesPage(before): %v", err)
	}
	if len(older) != 2 || older[0].Content != "m2" || older[1].Content != "m3" || !hasMore {
		t.Fatalf("更早一页应返回 [m2 m3] 且 hasMore=true，得到 %+v hasMore=%v", older, hasMore)
	}

	// 最后一页：m1，没有更早的了
	last, hasMore, err := s.MessagesPage("anan", "peppa", older[0].ID, 2)
	if err != nil {
		t.Fatalf("MessagesPage(last): %v", err)
	}
	if len(last) != 1 || last[0].Content != "m1" || hasMore {
		t.Fatalf("最后一页应只有 [m1] 且 hasMore=false，得到 %+v hasMore=%v", last, hasMore)
	}

	// 角色隔离
	if got, _, _ := s.MessagesPage("anan", "george", 0, 10); len(got) != 0 {
		t.Fatalf("不同角色不应串消息，得到 %d 条", len(got))
	}
}

func TestGetMessage(t *testing.T) {
	s := newTestStore(t)
	m := &model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai", Content: "hello"}
	if err := s.SaveMessage(m); err != nil {
		t.Fatalf("SaveMessage: %v", err)
	}

	got, err := s.GetMessage("anan", m.ID)
	if err != nil {
		t.Fatalf("GetMessage: %v", err)
	}
	if got == nil || got.Content != "hello" || got.Speaker != "ai" || got.RoleID != "peppa" {
		t.Fatalf("读回的消息不对: %+v", got)
	}

	// 跨宝宝 / 不存在都返回 nil
	if got, err := s.GetMessage("bob", m.ID); err != nil || got != nil {
		t.Fatalf("跨宝宝不应读到消息，得到 %+v err=%v", got, err)
	}
	if got, err := s.GetMessage("anan", 999999); err != nil || got != nil {
		t.Fatalf("不存在的消息应返回 nil，得到 %+v err=%v", got, err)
	}
}
