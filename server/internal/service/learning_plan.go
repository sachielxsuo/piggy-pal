package service

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"

	"piggy-pal/server/internal/model"
)

// 学习计划：每周一生成 7 天、每天 5 个目标词，聊天时由角色自然带入。
//
// 设计要点：
//   - 一周一个主题弧线：周一/周二主题 A（优先宝宝兴趣）→ 周三/周四主题 B（生活高频）
//     → 周五/周六主题 C（动作/颜色等可表演词）→ 周日复习本周词。避免每天换题材、词太散。
//   - 计划只生成一次（按 child_id + week_start 幂等），聊天时读库，不在每轮对话里调 LLM。
//   - 统计只认计划内的词：角色说到 = 听到，宝宝说出 = 说出，同一天同一个词只算一次。
const (
	planDays = 7
	// planWordsPerDay 每天的新词数：4 岁左右每天 5 个新词 + 周日复习。
	// 依据：学龄前儿童平均每天自然习得约 2–3 个词根；课堂式深教每周 3–5 个词；
	// 4 岁孩子要把一个新词记住，往往需要 10 次以上不同语境的接触（Neuman 的实验里
	// 80% 的孩子要 24 次才记住）。10 个/天摊到 10–15 分钟对话里，每个词只能出现 1 次，
	// 更像“听过”而不是“学会”。5 个/天能保证每个词反复出现 3–4 次。
	planWordsPerDay = 5
)

// planMu 串行化计划生成，避免首次进入时并发请求各生成一份。
var planMu sync.Mutex

// planTokenRE 只取纯字母 token，用于计划词匹配（不把缩写拆成两半）。
var planTokenRE = regexp.MustCompile(`[A-Za-z]+`)

// planWordRE 校验 LLM 给出的词：单个小写英文单词，2-9 个字母。
var planWordRE = regexp.MustCompile(`^[a-z]{2,9}$`)

// vocabTheme 兜底词库里的一个主题。
type vocabTheme struct {
	Name  string
	Words []model.PlanWord
}

// fallbackThemes 是 LLM 不可用时的兜底课程：三个主题各 20 词，覆盖两周各两天。
// 顺序按「动物 → 食物 → 动作/颜色」，保持和 LLM 计划一样的认知递进。
var fallbackThemes = []vocabTheme{
	{Name: "动物朋友", Words: []model.PlanWord{
		{En: "cat", Zh: "猫"}, {En: "dog", Zh: "狗"}, {En: "pig", Zh: "猪"}, {En: "cow", Zh: "奶牛"},
		{En: "duck", Zh: "鸭子"}, {En: "sheep", Zh: "绵羊"}, {En: "horse", Zh: "马"}, {En: "rabbit", Zh: "兔子"},
		{En: "bird", Zh: "鸟"}, {En: "fish", Zh: "鱼"}, {En: "bear", Zh: "熊"}, {En: "lion", Zh: "狮子"},
		{En: "tiger", Zh: "老虎"}, {En: "monkey", Zh: "猴子"}, {En: "elephant", Zh: "大象"}, {En: "panda", Zh: "熊猫"},
		{En: "frog", Zh: "青蛙"}, {En: "turtle", Zh: "乌龟"}, {En: "bee", Zh: "蜜蜂"}, {En: "butterfly", Zh: "蝴蝶"},
	}},
	{Name: "好吃的水果", Words: []model.PlanWord{
		{En: "apple", Zh: "苹果"}, {En: "banana", Zh: "香蕉"}, {En: "orange", Zh: "橙子"}, {En: "grape", Zh: "葡萄"},
		{En: "pear", Zh: "梨"}, {En: "peach", Zh: "桃子"}, {En: "milk", Zh: "牛奶"}, {En: "water", Zh: "水"},
		{En: "egg", Zh: "鸡蛋"}, {En: "bread", Zh: "面包"}, {En: "rice", Zh: "米饭"}, {En: "cake", Zh: "蛋糕"},
		{En: "juice", Zh: "果汁"}, {En: "cookie", Zh: "饼干"}, {En: "candy", Zh: "糖果"}, {En: "cheese", Zh: "奶酪"},
		{En: "soup", Zh: "汤"}, {En: "noodle", Zh: "面条"}, {En: "carrot", Zh: "胡萝卜"}, {En: "tomato", Zh: "番茄"},
	}},
	{Name: "动一动", Words: []model.PlanWord{
		{En: "red", Zh: "红色"}, {En: "blue", Zh: "蓝色"}, {En: "green", Zh: "绿色"}, {En: "yellow", Zh: "黄色"},
		{En: "pink", Zh: "粉色"}, {En: "black", Zh: "黑色"}, {En: "white", Zh: "白色"}, {En: "brown", Zh: "棕色"},
		{En: "run", Zh: "跑"}, {En: "jump", Zh: "跳"}, {En: "walk", Zh: "走"}, {En: "swim", Zh: "游泳"},
		{En: "fly", Zh: "飞"}, {En: "sit", Zh: "坐"}, {En: "stand", Zh: "站"}, {En: "eat", Zh: "吃"},
		{En: "drink", Zh: "喝"}, {En: "sleep", Zh: "睡觉"}, {En: "open", Zh: "打开"}, {En: "close", Zh: "关上"},
	}},
}

// PlanProgress 某一天计划词的完成情况。
type PlanProgress struct {
	PlanWords  int
	Heard      int
	Said       int
	HeardWords []string
	SaidWords  []string
	// TurnsSincePlanWord 最近连续几条宝宝发言里没有出现任何计划词。
	// 用来判断宝宝是不是跑题了：>=1 说明上一轮该拉回来了，>=2 必须强行桥接。
	TurnsSincePlanWord int
}

// planOffTopicLimit 连续跑题达到这个轮数就必须绕回主线，不能再跟着宝宝跑。
const planOffTopicLimit = 2

// weekStartOf 返回 date 所在周的周一（本地时区）。
func weekStartOf(t time.Time) time.Time {
	wd := int(t.Weekday())
	if wd == 0 {
		wd = 7
	}
	return t.AddDate(0, 0, -(wd - 1))
}

// EnsureWeekPlan 取当前周计划；没有就生成并落库。
// 返回的计划不含进度（heard/said 由调用方按需计算）。
func (s *ChatService) EnsureWeekPlan(ctx context.Context, childID string) (string, string, []model.PlanDay, error) {
	weekStart := weekStartOf(time.Now()).Format(dayLayout)

	source, days, found, err := s.store.GetLearningPlanWeek(childID, weekStart)
	if err != nil {
		return "", "", nil, err
	}
	if found && len(days) == planDays {
		return weekStart, source, days, nil
	}

	planMu.Lock()
	defer planMu.Unlock()

	// 双重检查：等锁期间别的请求可能已经生成好了。
	source, days, found, err = s.store.GetLearningPlanWeek(childID, weekStart)
	if err != nil {
		return "", "", nil, err
	}
	if found && len(days) == planDays {
		return weekStart, source, days, nil
	}

	child, _ := s.store.GetChild(childID)
	previous, _ := s.store.PreviousWeekWords(childID, weekStart)
	days, source = s.generateWeekPlan(ctx, child, weekStart, previous)
	if err := s.store.SaveLearningPlan(childID, weekStart, source, days); err != nil {
		return "", "", nil, err
	}
	slog.InfoContext(ctx, "学习计划已生成", "child_id", childID, "week_start", weekStart,
		"source", source, "days", len(days))
	return weekStart, source, days, nil
}

// LearningPlan 返回当前周计划 + 每一天的完成情况，供报告页 / 首页使用。
func (s *ChatService) LearningPlan(ctx context.Context, childID string) (*model.LearningPlan, error) {
	weekStart, source, days, err := s.EnsureWeekPlan(ctx, childID)
	if err != nil {
		return nil, err
	}
	weekStartT, err := time.Parse(dayLayout, weekStart)
	if err != nil {
		return nil, err
	}
	end := weekStartT.AddDate(0, 0, planDays-1).Format(dayLayout)

	progress, err := s.planProgress(ctx, childID, weekStart, end)
	if err != nil {
		return nil, err
	}
	today := time.Now().Format(dayLayout)

	out := &model.LearningPlan{
		ChildID:   childID,
		WeekStart: weekStart,
		Source:    source,
		Days:      make([]model.PlanDay, 0, len(days)),
	}
	for _, d := range days {
		if p := progress[d.Date]; p != nil {
			d.Heard = p.Heard
			d.Said = p.Said
			d.HeardWords = p.HeardWords
			d.SaidWords = p.SaidWords
		}
		if d.Date == today {
			out.Today = d
		}
		out.Days = append(out.Days, d)
	}
	if out.Today.Date == "" {
		out.Today = model.PlanDay{Date: today, Words: []model.PlanWord{}}
	}
	return out, nil
}

// PlanProgress 计算 [startDate, endDate] 内每天的计划词完成情况，供统计接口填数。
func (s *ChatService) PlanProgress(ctx context.Context, childID, startDate, endDate string) (map[string]*PlanProgress, error) {
	return s.planProgress(ctx, childID, startDate, endDate)
}

// planProgress 读取区间内已生成的计划日和对话，按天匹配计划词。
func (s *ChatService) planProgress(ctx context.Context, childID, startDate, endDate string) (map[string]*PlanProgress, error) {
	days, err := s.store.GetLearningPlanDays(childID, startDate, endDate)
	if err != nil {
		return nil, err
	}
	out := make(map[string]*PlanProgress, len(days))
	if len(days) == 0 {
		return out, nil
	}
	msgs, err := s.store.MessagesBetween(childID, startDate, endDate)
	if err != nil {
		return nil, err
	}

	aiByDate := map[string][]string{}
	childByDate := map[string][]string{}
	msgsByDate := map[string][]model.DatedMessage{}
	for _, m := range msgs {
		msgsByDate[m.Date] = append(msgsByDate[m.Date], m)
		if m.Speaker == "ai" {
			aiByDate[m.Date] = append(aiByDate[m.Date], m.Content)
		} else {
			childByDate[m.Date] = append(childByDate[m.Date], m.Content)
		}
	}

	for _, d := range days {
		heard := matchPlanWords(strings.Join(aiByDate[d.Date], " "), d.Words)
		said := matchPlanWords(strings.Join(childByDate[d.Date], " "), d.Words)
		out[d.Date] = &PlanProgress{
			PlanWords:          len(d.Words),
			Heard:              len(heard),
			Said:               len(said),
			HeardWords:         heard,
			SaidWords:          said,
			TurnsSincePlanWord: offTopicStreak(msgsByDate[d.Date], d.Words),
		}
	}
	return out, nil
}

// offTopicStreak 从最近一条消息往前数，连续多少条宝宝发言偏离了今日主线。
// 判定标准：
//   - 当天角色还没说过任何计划词时不算跑题（还没有可回的主线）；
//   - 宝宝说到计划词立即清零；
//   - 只数「有内容」的发言，yes / no / 嗯 这类简短回应既不加也不清零，
//     否则正常对话会被误判成跑题。
func offTopicStreak(msgs []model.DatedMessage, words []model.PlanWord) int {
	aiText := make([]string, 0, len(msgs)/2)
	childTexts := make([]string, 0, len(msgs)/2)
	for _, m := range msgs {
		if m.Speaker == "ai" {
			aiText = append(aiText, m.Content)
		} else {
			childTexts = append(childTexts, m.Content)
		}
	}
	if len(matchPlanWords(strings.Join(aiText, " "), words)) == 0 {
		return 0
	}

	turns := 0
	for i := len(childTexts) - 1; i >= 0; i-- {
		text := childTexts[i]
		if len(matchPlanWords(text, words)) > 0 {
			break
		}
		if isSubstantiveOffTopic(text) {
			turns++
		}
	}
	return turns
}

// isSubstantiveOffTopic 判断宝宝这句是不是「有内容但没说到目标词」。
// 简短回应（yes / no / 好 / 嗯）不算跑题，避免每轮都被要求拉回。
// 表达情绪 / 想结束的话也不算跑题：那是「该停下来」的信号，不是「该拐回主线」。
func isSubstantiveOffTopic(text string) bool {
	text = strings.TrimSpace(text)
	if text == "" || detectChildMood(text) != moodNeutral {
		return false
	}
	english := len(planTokenRE.FindAllString(text, -1))
	cjk := 0
	for _, r := range text {
		if unicode.Is(unicode.Han, r) {
			cjk++
		}
	}
	return english >= 2 || cjk >= 3
}

// matchPlanWords 返回 text 里出现过的计划词（保持计划中的顺序，去重）。
// 只做最简单的复数匹配（cat/cats），避免把 running 这类变形误判成别的词。
func matchPlanWords(text string, words []model.PlanWord) []string {
	if text == "" || len(words) == 0 {
		return nil
	}
	tokens := make(map[string]bool, 32)
	for _, t := range planTokenRE.FindAllString(text, -1) {
		tokens[strings.ToLower(t)] = true
	}
	out := make([]string, 0, len(words))
	seen := make(map[string]bool, len(words))
	for _, w := range words {
		en := strings.ToLower(strings.TrimSpace(w.En))
		if en == "" || seen[en] {
			continue
		}
		if tokens[en] || tokens[en+"s"] || tokens[en+"es"] {
			seen[en] = true
			out = append(out, en)
		}
	}
	return out
}

// todayPlan 取今天的计划日；没有今日计划时返回零值。
func (s *ChatService) todayPlan(ctx context.Context, childID string) (model.PlanDay, bool) {
	_, _, days, err := s.EnsureWeekPlan(ctx, childID)
	if err != nil || len(days) == 0 {
		if err != nil {
			slog.WarnContext(ctx, "读取学习计划失败", "child_id", childID, "err", err)
		}
		return model.PlanDay{}, false
	}
	today := time.Now().Format(dayLayout)
	for _, d := range days {
		if d.Date == today && len(d.Words) > 0 {
			return d, true
		}
	}
	return model.PlanDay{}, false
}

// childMood 宝宝这句话的情绪状态，决定这一轮还要不要继续教学。
//
// 真实对话里出现过：宝宝说「我不喜欢你干啥总是记不住」「我都不想跟你玩了」，
// 角色却继续追问同一个水果词。对 4-6 岁孩子来说，情绪永远优先于教学进度。
type childMood int

const (
	moodNeutral childMood = iota
	moodUpset             // 不喜欢 / 讨厌 / 生气 / 难过：先安抚，当轮不教学
	moodLeave             // 再见 / 不想玩 / 走开：尊重离开，不挽留
)

func (m childMood) String() string {
	switch m {
	case moodUpset:
		return "upset"
	case moodLeave:
		return "leave"
	default:
		return "neutral"
	}
}

// 只收 2 字以上的短语，避免「别」「烦」这类单字在正常句子里误伤。
var moodLeavePhrases = []string{
	"再见", "拜拜", "不想玩", "不玩了", "不跟你玩", "不想跟你玩", "走开", "你走吧", "我要走了",
}

var moodUpsetPhrases = []string{
	"不喜欢", "不想", "不要", "讨厌", "好烦", "烦死", "生气", "难过", "伤心", "委屈",
	"害怕", "凶我", "别问", "别说", "别管", "没意思", "无聊", "闭嘴", "哼", "不理你", "不理我",
}

// moodQuestionForms 是「要不要 / 想不想」这类 A 不 A 的疑问句式。
// 它们含「不要」「不想」，会被误判成拒绝，匹配前先剔掉。
var moodQuestionForms = []string{
	"喜欢不喜欢", "要不要", "想不想", "喜不喜欢", "是不是", "有没有", "好不好", "对不对", "会不会",
}

// detectChildMood 判断宝宝这句话是不是在表达情绪 / 想结束。
// 判定刻意保守：只有明确的拒绝、厌烦、道别才命中，普通陈述不会被打断。
func detectChildMood(text string) childMood {
	t := strings.TrimSpace(text)
	if t == "" {
		return moodNeutral
	}
	// 「要不要 / 想不想」是提议或提问，不是拒绝，先剔掉再匹配。
	for _, q := range moodQuestionForms {
		t = strings.ReplaceAll(t, q, "")
	}
	for _, p := range moodLeavePhrases {
		if strings.Contains(t, p) {
			return moodLeave
		}
	}
	for _, p := range moodUpsetPhrases {
		if strings.Contains(t, p) {
			return moodUpset
		}
	}
	return moodNeutral
}

// moodHint 情绪优先的对话提示：这一轮只照顾感受，不提任何目标词。
// 独立于学习计划生成，所以即使今天没有计划也会生效。
func moodHint(mood childMood) string {
	if mood == moodLeave {
		return "【宝宝想结束，先尊重他】\n" +
			"宝宝这句话是在道别 / 不想玩了。\n" +
			"1. 温和道别一句就够，可以留一句轻松的期待（想玩的时候再来找我）。\n" +
			"2. 不要挽留，不要谈条件（不要说「再回答一个问题就让你走」「再玩一下下」）。\n" +
			"3. 这一轮不要提任何英文单词，也不要问英语问题。\n" +
			"4. 如果宝宝只是随口说再见、其实还在聊，也先顺着他的话头，不要立刻拉回学习。\n"
	}
	return "【先照顾情绪，这一轮不教学】\n" +
		"宝宝这句话在表达不喜欢 / 难受 / 不想继续，不是在学习状态。\n" +
		"1. 先接住情绪：用一句话说出他的感受（比如「你不喜欢这样，我听到了」），态度认真，不要卖萌带过。\n" +
		"2. 不要嘴上答应、下一句又把话题拐回单词；也不要说「我记住了」然后原样再问一次。\n" +
		"3. 这一轮不要提任何目标词，不要问英语问题，不要提学习。\n" +
		"4. 给一个真实的选择（想换个游戏，还是先休息一下），让他自己决定。\n" +
		"5. 如果宝宝再次表达不想玩，就顺势道别，不要劝他「再玩一下下」。\n"
}

// recentAskedWords 统计最近两条 AI 发言里出现过的今日目标词。
//
// last  = 上一条 AI 说过的词（宝宝这一轮还没接上）
// twice = 连着两条 AI 都说过的词（已经在一个词上反复追问了）
//
// 同一个词连续追问是这次真实对话里最刺眼的问题（grape 被问了 6 轮），
// 所以这里不只看「说没说过」，还看「是不是刚问过」。
func (s *ChatService) recentAskedWords(ctx context.Context, childID, roleID string, words []model.PlanWord) (last, twice []string) {
	if len(words) == 0 || roleID == "" {
		return nil, nil
	}
	msgs, err := s.store.RecentMessages(childID, roleID, 6)
	if err != nil {
		slog.WarnContext(ctx, "读取最近对话失败，本轮不做重复抑制", "child_id", childID, "role_id", roleID, "err", err)
		return nil, nil
	}
	aiTexts := make([]string, 0, 2)
	for i := len(msgs) - 1; i >= 0 && len(aiTexts) < 2; i-- {
		if msgs[i].Speaker == "ai" {
			aiTexts = append(aiTexts, msgs[i].Content)
		}
	}
	if len(aiTexts) == 0 {
		return nil, nil
	}
	last = matchPlanWords(aiTexts[0], words)
	if len(aiTexts) < 2 {
		return last, nil
	}
	prev := matchPlanWords(aiTexts[1], words)
	if len(prev) == 0 || len(last) == 0 {
		return last, nil
	}
	prevSet := make(map[string]bool, len(prev))
	for _, w := range prev {
		prevSet[w] = true
	}
	for _, w := range last {
		if prevSet[w] {
			twice = append(twice, w)
		}
	}
	return last, twice
}

// learningHint 生成注入 system prompt 的「今日主线」段落。
// childText 是本轮宝宝刚说的话：它还没落库，但判断情绪、跑题和「刚说过的词」
// 必须算上，所以这里把它单独传进来。roleID 用来读最近两轮 AI 说了什么。
// 计划生成失败或今天没有计划时返回空串，对话照常进行。
func (s *ChatService) learningHint(ctx context.Context, childID, roleID, childText string) string {
	// 情绪优先：宝宝在表达不喜欢 / 想结束，这一轮直接放弃教学，不注入任何词。
	if mood := detectChildMood(childText); mood != moodNeutral {
		slog.InfoContext(ctx, "宝宝表达情绪，本轮暂停引导", "child_id", childID,
			"role_id", roleID, "mood", mood.String(), "text", truncateRunes(childText, 40))
		return moodHint(mood)
	}

	plan, ok := s.todayPlan(ctx, childID)
	if !ok {
		return ""
	}
	today := plan.Date

	progress, _ := s.planProgress(ctx, childID, today, today)
	p := progress[today]
	heard := map[string]bool{}
	said := map[string]bool{}
	streak := 0
	if p != nil {
		for _, w := range p.HeardWords {
			heard[strings.ToLower(w)] = true
		}
		for _, w := range p.SaidWords {
			said[strings.ToLower(w)] = true
		}
		streak = p.TurnsSincePlanWord
	}
	// 本轮发言还没入库：宝宝刚说了目标词就先按「已说」处理，跑题则把连续轮数 +1。
	justSaid := matchPlanWords(childText, plan.Words)
	for _, w := range justSaid {
		said[w] = true
	}
	if len(justSaid) > 0 {
		streak = 0
	} else if p != nil && p.Heard > 0 && isSubstantiveOffTopic(childText) {
		streak++
	}

	// 刚问过的词先压住：宝宝已经说过的词不再算「追问」，可以正常复现。
	lastAsked, askedTwice := s.recentAskedWords(ctx, childID, roleID, plan.Words)
	suppress := map[string]string{}
	for _, w := range lastAsked {
		if !said[w] {
			suppress[w] = "上一轮刚问过，宝宝还没接"
		}
	}
	for _, w := range askedTwice {
		if !said[w] {
			suppress[w] = "已经连着两轮追问，这一轮绝对不要再提"
		}
	}

	var newWords, heardNotSaid, saidWords, askable, avoid []string
	for _, w := range plan.Words {
		en := strings.ToLower(w.En)
		item := fmt.Sprintf("%s（%s）", en, w.Zh)
		switch {
		case said[en]:
			saidWords = append(saidWords, item)
		case heard[en]:
			heardNotSaid = append(heardNotSaid, item)
		default:
			newWords = append(newWords, item)
		}
		if said[en] {
			continue
		}
		if reason, blocked := suppress[en]; blocked {
			avoid = append(avoid, item+"："+reason)
		} else {
			askable = append(askable, item)
		}
	}

	var b strings.Builder
	b.WriteString("【今日对话主线】" + plan.Theme + "\n")
	b.WriteString("今天的目标词（一共 " + fmt.Sprint(len(plan.Words)) + " 个，分散在整段对话里慢慢出现，不是每轮都要用到）：\n")
	if len(newWords) > 0 {
		b.WriteString("- 还没出现：" + strings.Join(newWords, "、") + "\n")
	}
	if len(heardNotSaid) > 0 {
		b.WriteString("- 角色说过、宝宝还没说：" + strings.Join(heardNotSaid, "、") + "\n")
	}
	if len(saidWords) > 0 {
		b.WriteString("- 宝宝已经说过（表扬过就往下走，别反复考）：" + strings.Join(saidWords, "、") + "\n")
	}
	if len(askable) > 0 {
		b.WriteString("- 这一轮可以自然带出（最多选 1 个）：" + strings.Join(askable, "、") + "\n")
	} else {
		b.WriteString("- 这一轮没有适合再问的词：只陪玩、顺着宝宝聊，不要为了凑词硬问。\n")
	}
	if len(avoid) > 0 {
		b.WriteString("- 这一轮不要再提：" + strings.Join(avoid, "；") + "\n")
	}
	// 间隔重复：把今天到期、但不在今日计划里的旧词也带进来，换场景复现。
	// 只取 3 个，避免 prompt 太长、一轮塞太多词。
	if due, err := s.store.DueReviewWords(childID, today, 3); err == nil && len(due) > 0 {
		items := make([]string, 0, len(due))
		for _, w := range due {
			item := w.Word
			if zh := strings.TrimSpace(w.Zh); zh != "" {
				item += "（" + zh + "）"
			}
			items = append(items, item)
		}
		b.WriteString("- 到期复习（前几天学过，今天自然复现 1 个就够，不要罗列）：" +
			strings.Join(items, "、") + "\n")
	}

	b.WriteString("引导规则（优先级从高到低，和基础提示冲突时以本节为准）：\n" +
		"1. 像玩伴一样自然、好玩，把词藏进游戏和场景里；不是上课，不强迫跟读。\n" +
		"2. 宝宝提问、说自己的事、换个话题，先用一句话正面回应他，再决定要不要带词。不要每轮都硬拐回主线。\n" +
		"3. 每次回复最多带 1 个目标词，从「这一轮可以自然带出」里选；同一个词在宝宝说中之前最多问 2 轮，第 2 轮他还没接就换词或先陪玩，绝对不要第三次追问。\n" +
		"4. 每轮结尾的问题要简单到 1 个单词就能答（What's this? / Do you like grapes?），不要问开放大题，也不要连着用同一个句式。\n" +
		"5. 宝宝说出目标词：先用夸张语气表扬，清楚重复一遍，然后自然往下聊，不要马上考下一个。\n" +
		"6. 不要把词表念出来，不要说「今天我们学 5 个单词」「跟我读」这类课堂话术。\n" +
		"7. 宝宝说「不想」「不喜欢」「再见」这类话时，情绪优先：先回应感受，当轮不提词、不问英语问题。\n")

	switch {
	case streak >= planOffTopicLimit:
		b.WriteString(fmt.Sprintf("8. 【先跟一会儿】宝宝已经连续 %d 轮没接目标词了。别急着拐回主线：先顺着他的话题聊，最多自然带 1 个词；他要是还没兴趣，这一轮就只陪玩，不追问、不重复同一个问题。\n", streak))
	case streak == 1:
		b.WriteString("8. 【可以带回主线】宝宝上一轮没接目标词。这一轮先简短回应他，再用「对了 / 你看」这类轻桥接带 1 个词，不要生硬转折。\n")
	default:
		b.WriteString("8. 【保持主线】现在还在主线上：顺着宝宝的话往下聊，同时把这轮要带的词藏进场景里。\n")
	}
	return b.String()
}

// greetingPlanHint 给每日开场白用的轻量提示：只要 1 个还没出现的词，不塞整段对话规则。
func (s *ChatService) greetingPlanHint(ctx context.Context, childID string) string {
	plan, ok := s.todayPlan(ctx, childID)
	if !ok {
		return ""
	}
	progress, _ := s.planProgress(ctx, childID, plan.Date, plan.Date)
	heard := map[string]bool{}
	if p := progress[plan.Date]; p != nil {
		for _, w := range p.HeardWords {
			heard[strings.ToLower(w)] = true
		}
	}
	for _, w := range plan.Words {
		en := strings.ToLower(w.En)
		if !heard[en] {
			return fmt.Sprintf("今天的词汇主线是「%s」。开场第一句请自然带入 1 个词：%s（%s），不要提「学习计划」，也不要罗列其他词。",
				plan.Theme, en, w.Zh)
		}
	}
	return fmt.Sprintf("今天的词汇主线是「%s」。开场第一句请自然复现其中 1 个词，帮助宝宝巩固。", plan.Theme)
}

// generateWeekPlan 用 LLM 生成一周计划，校验不过则重试一次，再失败走兜底词库。
func (s *ChatService) generateWeekPlan(ctx context.Context, child *model.Child, weekStart string, previous []string) ([]model.PlanDay, string) {
	if s.llm != nil && s.llm.Enabled() {
		prompt := buildPlanPrompt(child, previous)
		for attempt := 0; attempt < 2; attempt++ {
			raw, err := s.llm.Chat(ctx, prompt, nil, "请生成本周英语词汇计划，只输出 JSON。")
			if err != nil {
				slog.WarnContext(ctx, "学习计划 LLM 调用失败", "err", err, "attempt", attempt+1)
				break
			}
			days, err := parsePlanDays(raw, weekStart)
			if err == nil {
				return days, "llm"
			}
			slog.WarnContext(ctx, "学习计划格式不合法，重试", "err", err, "attempt", attempt+1)
			prompt += fmt.Sprintf("\n注意：上一次输出不合法（%s）。必须严格按 JSON 结构输出 7 天、每天 %d 个不重复的单字英文单词。", err.Error(), planWordsPerDay)
		}
	}
	return fallbackPlan(weekStart), "fallback"
}

// buildPlanPrompt 组装一周计划生成提示词。兴趣优先，其次保证主题成块、难度递进。
func buildPlanPrompt(child *model.Child, previous []string) string {
	interest := "未填写"
	age := 4
	if child != nil {
		if p := strings.TrimSpace(child.Preferences); p != "" {
			interest = truncateRunes(p, 60)
		}
		if child.Age > 0 {
			age = child.Age
		}
	}

	parts := []string{
		fmt.Sprintf("你在给一个 %d 岁的中国宝宝设计一周英语词汇学习计划，词汇会由聊天玩伴在多轮对话里自然带入。", age),
		"宝宝兴趣：" + interest,
	}
	if len(previous) > 0 {
		parts = append(parts, "上一周已经学过的词（本周尽量避开，最多在周日复习里保留 2-3 个）："+strings.Join(previous, ", "))
	}
	parts = append(parts,
		"结构要求（必须严格遵守）：\n"+
			"- 一共 7 天，周一到周日，每天正好 5 个词（3-6 岁每天 5 个新词最合适，宁可少而反复）。\n"+
			"- 周一、周二：同一个主题 A，两天各 5 个不同词，从易到难。主题 A 优先贴合宝宝兴趣。\n"+
			"- 周三、周四：同一个主题 B，选食物、水果、日常用品这类高频生活词，两天各 5 个。\n"+
			"- 周五：主题 C1，选能边说边做的动作词（如 jump、clap、run），5 个。\n"+
			"- 周六：主题 C2，从颜色、身体部位、情绪里只选一类，5 个，不要混在一起。\n"+
			"- 周日：复习日，从 A/B/C 里挑本周出现过的词凑满 5 个，不引入新词。\n"+
			"- 周一到周六尽量不重复；同一个词最多出现 2 次，且不要连续两天都出现（间隔复习可以）。\n"+
			"- 每个词必须是单个英文单词（不能有空格），2-9 个小写字母，用单数原形（不要 cats、rocks 这类复数），具体、可指物或可做动作，适合 3-6 岁；不要抽象词，不要中文直译的怪英文。\n"+
			"- zh 是给家长看的中文意思，2-4 个字。theme 用 2-6 个中文字概括当天主题。\n"+
			"- 只输出 JSON，不要解释、不要 markdown 代码块。\n"+
			`格式：{"days":[{"theme":"农场动物","words":[{"en":"cat","zh":"猫"}, ...共5个]}, ...共7天]}`)
	return strings.Join(parts, "\n")
}

// parsePlanDays 解析并校验 LLM 输出。
func parsePlanDays(raw, weekStart string) ([]model.PlanDay, error) {
	raw = strings.TrimSpace(raw)
	if i, j := strings.Index(raw, "{"), strings.LastIndex(raw, "}"); i >= 0 && j > i {
		raw = raw[i : j+1]
	}
	var payload struct {
		Days []struct {
			Theme string           `json:"theme"`
			Words []model.PlanWord `json:"words"`
		} `json:"days"`
	}
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		return nil, fmt.Errorf("JSON 解析失败")
	}
	if len(payload.Days) != planDays {
		return nil, fmt.Errorf("必须是 7 天，实际 %d 天", len(payload.Days))
	}

	start, err := time.Parse(dayLayout, weekStart)
	if err != nil {
		return nil, err
	}

	seen := map[string]bool{}
	count := map[string]int{}
	days := make([]model.PlanDay, 0, planDays)
	for i, d := range payload.Days {
		if len(d.Words) != planWordsPerDay {
			return nil, fmt.Errorf("第 %d 天必须是 %d 个词", i+1, planWordsPerDay)
		}
		words := make([]model.PlanWord, 0, planWordsPerDay)
		daySeen := map[string]bool{}
		for _, w := range d.Words {
			en := strings.ToLower(strings.TrimSpace(w.En))
			zh := strings.TrimSpace(w.Zh)
			if !planWordRE.MatchString(en) {
				return nil, fmt.Errorf("单词「%s」不是 2-9 个小写字母", w.En)
			}
			if zh == "" {
				return nil, fmt.Errorf("单词 %s 缺少中文释义", en)
			}
			if daySeen[en] {
				return nil, fmt.Errorf("第 %d 天有重复单词 %s", i+1, en)
			}
			daySeen[en] = true
			if i < planDays-1 {
				seen[en] = true
				count[en]++
				if count[en] > 2 {
					return nil, fmt.Errorf("单词 %s 一周内出现超过 2 次", en)
				}
			}
			words = append(words, model.PlanWord{En: en, Zh: truncateRunes(zh, 8)})
		}
		// 周日必须是本周词的复习：不允许出现前 6 天没出现过的词。
		if i == planDays-1 {
			for _, w := range words {
				if !seen[w.En] {
					return nil, fmt.Errorf("周日复习词 %s 不在本周计划里", w.En)
				}
			}
		}
		theme := strings.TrimSpace(d.Theme)
		if theme == "" {
			theme = fmt.Sprintf("第 %d 天", i+1)
		}
		days = append(days, model.PlanDay{
			Date:     start.AddDate(0, 0, i).Format(dayLayout),
			DayIndex: i,
			Theme:    truncateRunes(theme, 12),
			Words:    words,
		})
	}
	return days, nil
}

// fallbackPlan 兜底计划：按「动物 → 食物 → 动作/颜色 → 复习」生成。
// 按周数轮换词序，避免每周完全一样。
func fallbackPlan(weekStart string) []model.PlanDay {
	start, err := time.Parse(dayLayout, weekStart)
	if err != nil {
		start = time.Now()
	}
	rotate := int(start.Unix()/86400) % len(fallbackThemes[0].Words)

	lists := make([][]model.PlanWord, 0, len(fallbackThemes))
	for _, t := range fallbackThemes {
		lists = append(lists, rotateWords(t.Words, rotate))
	}

	days := make([]model.PlanDay, 0, planDays)
	themes := []string{
		fallbackThemes[0].Name, fallbackThemes[0].Name,
		fallbackThemes[1].Name, fallbackThemes[1].Name,
		fallbackThemes[2].Name, fallbackThemes[2].Name,
		"本周复习",
	}
	for i := 0; i < planDays; i++ {
		var words []model.PlanWord
		if i == planDays-1 {
			// 复习日：每个主题挑几个，凑满 5 个，优先靠前的词。
			words = append(words, lists[0][0:2]...)
			words = append(words, lists[1][0:2]...)
			words = append(words, lists[2][0:1]...)
		} else {
			themeIdx := i / 2
			offset := (i % 2) * planWordsPerDay
			words = append(words, lists[themeIdx][offset:offset+planWordsPerDay]...)
		}
		days = append(days, model.PlanDay{
			Date:     start.AddDate(0, 0, i).Format(dayLayout),
			DayIndex: i,
			Theme:    themes[i],
			Words:    words,
		})
	}
	return days
}

// rotateWords 返回向左轮换 offset 位后的副本。
func rotateWords(words []model.PlanWord, offset int) []model.PlanWord {
	n := len(words)
	if n == 0 {
		return nil
	}
	offset = ((offset % n) + n) % n
	out := make([]model.PlanWord, 0, n)
	out = append(out, words[offset:]...)
	out = append(out, words[:offset]...)
	return out
}
