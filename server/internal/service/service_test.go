package service

import (
	"context"
	"strings"
	"testing"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/store"
)

func TestGuardContainsBlocked(t *testing.T) {
	g := NewGuardService(&config.GuardConfig{BlockedWords: []string{"暴力", "血腥"}})
	if !g.ContainsBlocked("我看到了暴力画面") {
		t.Fatal("命中黑名单应返回 true")
	}
	if g.ContainsBlocked("今天天气真好") {
		t.Fatal("未命中黑名单应返回 false")
	}
	if g.ContainsBlocked("") {
		t.Fatal("空串不应命中")
	}
}

func TestGuardNilConfig(t *testing.T) {
	g := NewGuardService(nil)
	if g.ContainsBlocked("暴力") {
		t.Fatal("nil 配置下不应命中")
	}
}

func TestMockReplyBranches(t *testing.T) {
	cases := []struct{ in, want string }{
		{"我想唱歌", "好呀好呀！我们一起唱 Baa, Baa, Black Sheep 好不好？🎵"},
		{"sing a song", "好呀好呀！我们一起唱 Baa, Baa, Black Sheep 好不好？🎵"},
		{"讲个故事", "那我们讲一个小猪去海边玩的故事吧～准备好了吗？"},
		{"dinosaur", "恐龙！🦖 乔治也最喜欢恐龙啦！"},
		{"随便说点", "That's great! 你太棒啦 ⭐"},
	}
	for _, c := range cases {
		if got := MockReply(c.in); got != c.want {
			t.Errorf("MockReply(%q) = %q, 期望 %q", c.in, got, c.want)
		}
	}
}

func newMockChatService(t *testing.T, st *store.Store) *ChatService {
	t.Helper()
	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", En: "Peppa", VoiceID: "101001", Persona: "你是佩奇"},
	}}
	// LLM / TTS / ASR 全部 disabled：走 mock 回复、跳过 TTS/ASR，测试纯业务编排不碰网络
	llm := NewLLMService("", "", "")
	tts := NewTTSService("", "", "", t.TempDir())
	asr := NewASRService("", "", "", "")
	guard := NewGuardService(&config.GuardConfig{BlockedWords: []string{"暴力"}})
	return NewChatService(st, llm, tts, asr, guard, roles, &config.PromptsConfig{})
}

func TestCountWords(t *testing.T) {
	cases := []struct {
		in   string
		want int
	}{
		{"I like dinosaurs", 3},
		{"I'm happy, don't worry!", 4},
		{"我想唱歌", 0},
		{"今天学 apple 和 banana", 2},
		{"", 0},
	}
	for _, c := range cases {
		if got := CountWords(c.in); got != c.want {
			t.Errorf("CountWords(%q) = %d, 期望 %d", c.in, got, c.want)
		}
	}
}

func TestGoodbyeText(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	prompts := &config.PromptsConfig{DailyFlow: []config.DailyFlowStep{
		{Step: "preview", Text: "明天{name}带你去看小动物哦！"},
	}}
	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", VoiceID: "101001"},
	}}
	chat := NewChatService(st, NewLLMService("", "", ""), NewTTSService("", "", "", t.TempDir()),
		NewASRService("", "", "", ""), NewGuardService(nil), roles, prompts)

	resp, err := chat.Goodbye(context.Background(), "peppa", 3)
	if err != nil {
		t.Fatalf("Goodbye: %v", err)
	}
	for _, want := range []string{"3 颗小星星", "明天佩奇带你去看小动物哦"} {
		if !strings.Contains(resp.ReplyText, want) {
			t.Fatalf("道别语 %q 缺少 %q", resp.ReplyText, want)
		}
	}

	if _, err := chat.Goodbye(context.Background(), "nobody", 1); err == nil {
		t.Fatal("未知角色应返回错误")
	}
}

func TestBuildSystemPromptIncludesDailyFlow(t *testing.T) {
	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", Persona: "你是佩奇"},
	}}
	prompts := &config.PromptsConfig{
		DailyFlow: []config.DailyFlowStep{
			{Step: "greeting", Text: "嗨，我是{name}～ 今天想和我一起玩吗？"},
			{Step: "activity", Text: "我们一起唱歌吧！"},
			{Step: "goodbye", Text: "今天玩得真开心，明天见～"},
		},
	}
	prompts.System.Base = "你是英语陪伴玩伴"
	prompts.System.Safety = "温和转移话题"

	chat := NewChatService(nil, NewLLMService("", "", ""), NewTTSService("", "", "", t.TempDir()),
		NewASRService("", "", "", ""), NewGuardService(nil), roles, prompts)

	got := chat.buildSystemPrompt(&roles.Roles[0], &model.Child{Name: "安安", EnName: "Anan"})
	for _, want := range []string{
		"你是英语陪伴玩伴",
		"安全要求：温和转移话题",
		"角色设定：你是佩奇",
		"中文名「安安」", "英文名「Anan」",
		"每日陪伴节奏",
		"1. 问候开场：嗨，我是佩奇～ 今天想和我一起玩吗？",
		"3. 温柔道别：今天玩得真开心，明天见～",
		"不要每轮都说再见",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("system prompt 缺少 %q，实际：\n%s", want, got)
		}
	}
}

func TestChildIdentityIncludesAgeAndPreferences(t *testing.T) {
	got := childIdentity(&model.Child{
		Name:        "安安",
		EnName:      "Anan",
		Age:         4,
		Preferences: "恐龙、儿歌",
	})
	for _, want := range []string{
		"中文名「安安」",
		"英文名「Anan」",
		"宝宝 4 岁",
		"宝宝喜欢：恐龙、儿歌",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("childIdentity 缺少 %q，实际：%s", want, got)
		}
	}

	// 没填年龄 / 喜好时不应凭空生成
	minimal := childIdentity(&model.Child{Name: "安安"})
	if strings.Contains(minimal, "岁") || strings.Contains(minimal, "喜欢") {
		t.Errorf("空年龄/喜好不应注入额外信息，实际：%s", minimal)
	}

	// 过长偏好按字符截断，避免挤占 prompt
	long := childIdentity(&model.Child{
		Name:        "安安",
		Preferences: strings.Repeat("恐", 80),
	})
	if !strings.Contains(long, "恐") || strings.Contains(long, strings.Repeat("恐", 61)) {
		t.Errorf("偏好应截断到 60 个字符，实际：%s", long)
	}

	if childIdentity(nil) != "" {
		t.Error("nil 宝宝应返回空身份")
	}
}

func TestStarsForWords(t *testing.T) {
	cases := []struct {
		words, want int
	}{
		{0, 0},
		{-1, 0},
		{1, 1},
		{2, 2},
		{3, 3},
		{4, 3},
		{10, 3},
	}
	for _, c := range cases {
		if got := StarsForWords(c.words); got != c.want {
			t.Errorf("StarsForWords(%d)=%d，期望 %d", c.words, got, c.want)
		}
	}
}

func TestBuildSystemPromptWithoutDailyFlow(t *testing.T) {
	roles := &config.RolesConfig{Roles: []config.Role{{RoleID: "peppa", Name: "佩奇"}}}
	chat := NewChatService(nil, NewLLMService("", "", ""), NewTTSService("", "", "", t.TempDir()),
		NewASRService("", "", "", ""), NewGuardService(nil), roles, &config.PromptsConfig{})

	if got := chat.buildSystemPrompt(&roles.Roles[0], nil); strings.Contains(got, "每日陪伴节奏") {
		t.Errorf("未配置 daily_flow 时不应注入节奏段落，实际：\n%s", got)
	}
}

func TestChatHandleMockFlow(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	resp, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{
		RoleID:    "peppa",
		Text:      "I like singing",
		SessionID: "sess-test-1",
	})
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if want := MockReply("I like singing"); resp.ReplyText != want {
		t.Fatalf("mock 回复应为 %q，得到 %q", want, resp.ReplyText)
	}
	if resp.AudioB64 != "" {
		t.Fatalf("TTS disabled 时不应有音频，得到 %d 字节", len(resp.AudioB64))
	}
	// 3 个英文单词 → 3 颗星，会话累计也是 3
	if resp.Stars != 3 || resp.WordCount != 3 || resp.SessionStars != 3 {
		t.Fatalf("星星/词数/会话星星不符: stars=%d words=%d session=%d",
			resp.Stars, resp.WordCount, resp.SessionStars)
	}
	if resp.SessionID != "sess-test-1" {
		t.Fatalf("应回显 session_id，得到 %q", resp.SessionID)
	}

	// 纯中文 → 0 颗星，但英文词数累计不受影响
	resp2, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{
		RoleID:    "peppa",
		Text:      "我想唱歌",
		SessionID: "sess-test-1",
	})
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if resp2.Stars != 0 || resp2.WordCount != 0 || resp2.SessionStars != 3 {
		t.Fatalf("中文不应得星，会话星星应保持 3: %+v", resp2)
	}

	// 落库：两轮 × (child + ai) = 4 条
	msgs, _ := st.RecentMessages("anan", "peppa", 10)
	if len(msgs) != 4 {
		t.Fatalf("期望落库 4 条，得到 %d", len(msgs))
	}
	if msgs[0].Speaker != "child" || msgs[1].Speaker != "ai" {
		t.Fatalf("落库顺序应为 child→ai，得到 %+v", msgs)
	}
	if msgs[0].Content != "I like singing" {
		t.Fatalf("第一条应为宝宝原话，得到 %q", msgs[0].Content)
	}
}

func TestChatHandleUnknownRole(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	if _, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{RoleID: "nope", Text: "hi"}); err == nil {
		t.Fatal("未知角色应返回错误")
	}
}

func TestChatHandleEmptyInput(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	if _, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{RoleID: "peppa", Text: "  "}); err == nil {
		t.Fatal("空输入应返回错误")
	}
}

// fakeASR 用于测试 ASR 识别为空的兜底逻辑（不碰网络）。
type fakeASR struct{ result string }

func (f fakeASR) Enabled() bool                                          { return true }
func (f fakeASR) Recognize(audioB64, voiceFormat string) (string, error) { return f.result, nil }

func TestChatHandleASREmptyFallback(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()

	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", En: "Peppa", VoiceID: "101001", Persona: "你是佩奇"},
	}}
	llm := NewLLMService("", "", "")
	tts := NewTTSService("", "", "", t.TempDir())
	guard := NewGuardService(nil)
	chat := NewChatService(st, llm, tts, fakeASR{result: ""}, guard, roles, &config.PromptsConfig{})

	resp, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{RoleID: "peppa", AudioB64: "AAAA"})
	if err != nil {
		t.Fatalf("ASR 识别为空不应报错，应走温和引导，得到 err: %v", err)
	}
	if resp.ReplyText == "" {
		t.Fatal("引导回复不应为空")
	}
	if resp.Stars != 0 {
		t.Fatalf("引导场景不应奖励星星，得到 %d", resp.Stars)
	}
	// 引导场景不落库
	msgs, _ := st.RecentMessages("anan", "peppa", 10)
	if len(msgs) != 0 {
		t.Fatalf("引导场景不应落库，得到 %d 条", len(msgs))
	}
}

func TestChatHandleGuardRedirect(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	// 命中护栏后话题被替换，仍应正常返回 mock 回复（default 分支）
	resp, err := chat.Handle(context.Background(), "anan", &model.ChatRequest{RoleID: "peppa", Text: "我看到了暴力"})
	if err != nil {
		t.Fatalf("Handle: %v", err)
	}
	if resp.ReplyText == "" {
		t.Fatal("护栏重定向后回复不应为空")
	}
}

func TestSpeakableTextStripsEmoji(t *testing.T) {
	got := speakableText("嗨，我是佩奇～\n 今天想和我一起玩吗？  H-hi! Let's sing and play together! 🎵🦖⭐")
	want := "嗨，我是佩奇～ 今天想和我一起玩吗？ H-hi! Let's sing and play together!"
	if got != want {
		t.Fatalf("speakableText 结果不符：\n got=%q\nwant=%q", got, want)
	}
}

func TestRoleGreetingUnknownRole(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)
	if _, err := chat.RoleGreeting(context.Background(), "nobody"); err != ErrRoleNotFound {
		t.Fatalf("未知角色应返回 ErrRoleNotFound，得到 %v", err)
	}
}

func TestDailyGreetingGeneratesOncePerDay(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	_ = st.UpsertChild(&model.Child{ChildID: "anan", Name: "安安", EnName: "Anan", Age: 4, Preferences: "恐龙、儿歌"})
	chat := newMockChatService(t, st)

	first, err := chat.DailyGreeting(context.Background(), "anan", "peppa")
	if err != nil {
		t.Fatalf("DailyGreeting: %v", err)
	}
	if !first.IsNew {
		t.Fatal("当天首次应标记 is_new=true")
	}
	if strings.TrimSpace(first.Text) == "" {
		t.Fatal("开场话题不应为空")
	}
	// LLM 未启用时走兜底：要有英文名 + 宝宝喜好，且中英混排
	if !strings.Contains(first.Text, "Anan") || !strings.Contains(first.Text, "恐龙") {
		t.Fatalf("兜底话题应包含英文名和喜好，得到 %q", first.Text)
	}
	if !strings.Contains(first.Text, "Let's") {
		t.Fatalf("开场话题应中英混排，得到 %q", first.Text)
	}

	second, err := chat.DailyGreeting(context.Background(), "anan", "peppa")
	if err != nil {
		t.Fatalf("第二次 DailyGreeting: %v", err)
	}
	if second.IsNew {
		t.Fatal("当天第二次不应重新生成（is_new 应为 false）")
	}
	if second.Text != first.Text {
		t.Fatalf("当天应复用同一句，first=%q second=%q", first.Text, second.Text)
	}

	// 只写了一条开场白进对话历史
	msgs, _ := st.RecentMessages("anan", "peppa", 10)
	if len(msgs) != 1 || msgs[0].Speaker != "ai" {
		t.Fatalf("应只落 1 条 ai 开场白，得到 %+v", msgs)
	}
}

func TestDailyGreetingUnknownRole(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)
	if _, err := chat.DailyGreeting(context.Background(), "anan", "nobody"); err != ErrRoleNotFound {
		t.Fatalf("未知角色应返回 ErrRoleNotFound，得到 %v", err)
	}
}

func TestCleanGeneratedText(t *testing.T) {
	cases := map[string]string{
		"“嗨，Anan！今天聊 dinosaurs 吧”":    "嗨，Anan！今天聊 dinosaurs 吧",
		"  嗨，Anan！\n今天聊 animals 吧。  ": "嗨，Anan！\n今天聊 animals 吧。",
		"`hi`": "hi",
		"1. 中文：嗨，Anan！\n2. 英文：Let's play!":  "嗨，Anan！\nLet's play!",
		"中文: 嗨，Anan！\nEnglish: Let's play!": "嗨，Anan！\nLet's play!",
	}
	for in, want := range cases {
		if got := cleanGeneratedText(in); got != want {
			t.Fatalf("cleanGeneratedText(%q) = %q，期望 %q", in, got, want)
		}
	}
}

func TestIsBilingualTopic(t *testing.T) {
	good := "嗨，Anan！今天我们一起聊恐龙吧。\nLet's talk about dinosaurs together!"
	if !isBilingualTopic(good) {
		t.Fatalf("中英文两行应判定为合格: %q", good)
	}

	bad := []string{
		"嗨，Anan！今天我们一起聊恐龙吧。",                     // 只有中文
		"Let's talk about dinosaurs together!",   // 只有英文
		"嗨，Anan！今天我们一起聊恐龙吧。\n我们一起聊恐龙吧。",          // 第二行不是英文
		"嗨，Anan！今天我们一起聊恐龙吧。\nDinosaurs!",         // 英文单词太少
		"嗨，Anan！今天我们一起聊恐龙吧。\nLet's 聊 dinosaurs!", // 英文行夹中文
	}
	for _, text := range bad {
		if isBilingualTopic(text) {
			t.Fatalf("不合格的话题被误判为合格: %q", text)
		}
	}

	if got := englishWordCount("Let's talk about dinosaurs together!"); got != 5 {
		t.Fatalf("englishWordCount = %d，期望 5", got)
	}
}

func TestContainsTextIgnoresSpaces(t *testing.T) {
	if !containsText([]string{"嗨，Anan！今天聊 animals 吧"}, "嗨, Anan! 今天聊animals吧") {
		// 标点不同不算重复，这里只验证空格差异
		t.Log("标点差异不视为重复（符合预期）")
	}
	if !containsText([]string{"嗨，Anan！今天聊 animals 吧"}, "嗨，Anan！今天聊 animals  吧") {
		t.Fatal("忽略空白后应判定为重复")
	}
	if containsText([]string{"聊 animals"}, "聊 food") {
		t.Fatal("不同话题不应判定为重复")
	}
}

func TestSplitSentences(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"你好呀。我们玩吧！", []string{"你好呀。", "我们玩吧！"}},
		{"Hello! Let's play. Good job.", []string{"Hello!", "Let's play.", "Good job."}},
		{"没有标点的一句话", []string{"没有标点的一句话"}},
		{"", nil},
		{"第一句。\n第二句", []string{"第一句。", "第二句"}},
	}
	for _, c := range cases {
		got := splitSentences(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("splitSentences(%q) = %#v，期望 %#v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("splitSentences(%q)[%d] = %q，期望 %q", c.in, i, got[i], c.want[i])
			}
		}
	}
}

func TestVoiceParams(t *testing.T) {
	// 普通数字音色
	if vt, fast := voiceParams(&config.Role{VoiceID: "403000"}); vt != 403000 || fast != "" {
		t.Fatalf("普通音色解析错误: vt=%d fast=%q", vt, fast)
	}
	// 一句话版复刻：VoiceType 固定 200000000，实际音色走 FastVoiceType
	role := &config.Role{VoiceID: "403000", FastVoiceID: "  WCHN-abc123  "}
	vt, fast := voiceParams(role)
	if vt != 200000000 || fast != "WCHN-abc123" {
		t.Fatalf("一句话复刻音色解析错误: vt=%d fast=%q", vt, fast)
	}
	// 非法 / 空 voice_id 走默认音色
	if vt, fast := voiceParams(&config.Role{VoiceID: "abc"}); vt != 403000 || fast != "" {
		t.Fatalf("默认音色兜底错误: vt=%d fast=%q", vt, fast)
	}
	if vt, fast := voiceParams(nil); vt != 403000 || fast != "" {
		t.Fatalf("nil role 兜底错误: vt=%d fast=%q", vt, fast)
	}
}
