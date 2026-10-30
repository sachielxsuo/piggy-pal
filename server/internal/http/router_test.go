package http

import (
	"bytes"
	"encoding/json"
	nethttp "net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/service"
	"piggy-pal/server/internal/store"
)

func newTestRouter(t *testing.T) *gin.Engine {
	return newTestRouterWithToken(t, "")
}

func newTestRouterWithToken(t *testing.T, token string) *gin.Engine {
	return newTestRouterWithRelease(t, token, t.TempDir())
}

func newTestRouterWithRelease(t *testing.T, token, releaseDir string) *gin.Engine {
	t.Helper()
	return newTestRouterWithAdmin(t, token, releaseDir, "")
}

// newTestRouterWithAdmin 额外指定运维管理令牌（空 = /admin 关闭）。
func newTestRouterWithAdmin(t *testing.T, token, releaseDir, adminToken string) *gin.Engine {
	t.Helper()
	return newTestRouterFull(t, token, t.TempDir(), releaseDir, adminToken)
}

// newTestRouterFull 可指定客户端日志目录，便于断言按设备隔离的落盘路径。
func newTestRouterFull(t *testing.T, token, clientLogDir, releaseDir, adminToken string) *gin.Engine {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", En: "Peppa", VoiceID: "101001", Catchphrase: "嗨，我是佩奇～"},
	}}
	// LLM / TTS / ASR 全部 disabled：对话走 mock、跳过语音，测试 HTTP 主链路
	llm := service.NewLLMService("", "", "")
	tts := service.NewTTSService("", "", "", t.TempDir())
	asr := service.NewASRService("", "", "", "")
	guard := service.NewGuardService(nil)
	chat := service.NewChatService(st, llm, tts, asr, guard, roles, &config.PromptsConfig{})

	return NewRouter(st, roles, chat, token, clientLogDir, releaseDir, adminToken, NewHealth())
}

// do 发送一个 JSON 请求并返回 recorder。
func do(t *testing.T, r *gin.Engine, method, path string, body any) *httptest.ResponseRecorder {
	return doWithToken(t, r, method, path, body, "")
}

func doWithToken(t *testing.T, r *gin.Engine, method, path string, body any, token string) *httptest.ResponseRecorder {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = bytes.NewReader(b)
	} else {
		reader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, reader)
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("X-API-Token", token)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func decodeJSON(t *testing.T, w *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatalf("解析响应 JSON 失败: %v，body=%s", err, w.Body.String())
	}
	return out
}

func TestHealthz(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodGet, "/healthz", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("healthz 状态码应为 200，得到 %d", w.Code)
	}
	if body := decodeJSON(t, w); body["status"] != "ok" {
		t.Fatalf("healthz 应返回 ok，得到 %v", body["status"])
	}
}

func TestListRoles(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodGet, "/roles", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("roles 状态码应为 200，得到 %d", w.Code)
	}
	body := decodeJSON(t, w)
	roles, ok := body["roles"].([]any)
	if !ok || len(roles) != 1 {
		t.Fatalf("roles 应包含 1 个角色，得到 %v", body["roles"])
	}
}

func TestChildCRUD(t *testing.T) {
	r := newTestRouter(t)

	// 创建
	w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "anan", "name": "安安", "en_name": "Anan", "age": 4,
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("创建宝宝状态码应为 200，得到 %d: %s", w.Code, w.Body.String())
	}

	// 查询单个
	w = do(t, r, nethttp.MethodGet, "/child/anan", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("查询宝宝状态码应为 200，得到 %d", w.Code)
	}
	if body := decodeJSON(t, w); body["name"] != "安安" {
		t.Fatalf("宝宝名字应为 安安，得到 %v", body["name"])
	}

	// 列表
	w = do(t, r, nethttp.MethodGet, "/child", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("宝宝列表状态码应为 200，得到 %d", w.Code)
	}
	body := decodeJSON(t, w)
	children, ok := body["children"].([]any)
	if !ok || len(children) != 1 {
		t.Fatalf("宝宝列表应包含 1 个，得到 %v", body["children"])
	}

	// 不存在的宝宝
	w = do(t, r, nethttp.MethodGet, "/child/nobody", nil)
	if w.Code != nethttp.StatusNotFound {
		t.Fatalf("不存在宝宝应返回 404，得到 %d", w.Code)
	}
}

func TestChatText(t *testing.T) {
	r := newTestRouter(t)

	w := do(t, r, nethttp.MethodPost, "/child/anan/chat", map[string]any{
		"role_id": "peppa", "text": "我想唱歌",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("对话状态码应为 200，得到 %d: %s", w.Code, w.Body.String())
	}
	body := decodeJSON(t, w)
	reply, _ := body["reply_text"].(string)
	if reply == "" {
		t.Fatal("对话回复不应为空")
	}
	if reply != service.MockReply("我想唱歌") {
		t.Fatalf("mock 回复不符，得到 %q", reply)
	}
}

func TestStatsSessionAndGoodbye(t *testing.T) {
	r := newTestRouter(t)

	w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "anan", "name": "安安", "en_name": "Anan",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("创建宝宝失败: %d %s", w.Code, w.Body.String())
	}

	// 一次对话（3 个英文单词）→ 3 颗星星 + 1 次开口
	w = do(t, r, nethttp.MethodPost, "/child/anan/chat", map[string]any{
		"role_id": "peppa", "text": "I like apples", "session_id": "sess-http",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("对话失败: %d %s", w.Code, w.Body.String())
	}
	chatBody := decodeJSON(t, w)
	// 兜底课程按周轮换（fallbackPlan 里 rotate 依赖 weekStart），苹果不一定在目标词里。
	// 所以期望值 = 3 个字 + 当轮的目标词奖励，不能写死。
	bonus, _ := chatBody["target_bonus"].(float64)
	wantStars := float64(3) + bonus
	if chatBody["stars"] != wantStars || chatBody["session_stars"] != wantStars {
		t.Fatalf("本轮/会话星星不符（期望 %v）: %v", wantStars, chatBody)
	}

	// 客户端防抖同步会话星星（幂等：同值不重复加星）
	w = do(t, r, nethttp.MethodPost, "/child/anan/session/sync", map[string]any{
		"session_id": "sess-http", "stars": wantStars,
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("同步会话星星失败: %d %s", w.Code, w.Body.String())
	}
	if got := decodeJSON(t, w)["session_stars"]; got != wantStars {
		t.Fatalf("同步后会话星星应为 %v，得到 %v", wantStars, got)
	}

	// 结束会话上报时长 / 打开次数
	w = do(t, r, nethttp.MethodPost, "/child/anan/session", map[string]any{
		"duration_sec": 90, "open_count": 1, "session_id": "sess-http",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("上报会话失败: %d %s", w.Code, w.Body.String())
	}

	w = do(t, r, nethttp.MethodGet, "/child/anan/stats", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("统计接口失败: %d %s", w.Code, w.Body.String())
	}
	body := decodeJSON(t, w)
	today, _ := body["today"].(map[string]any)
	if today["stars"] != wantStars || today["duration_sec"] != float64(90) {
		t.Fatalf("今日星星/时长不符: %v", today)
	}
	if today["utterances"] != float64(1) || body["total_utterances"] != float64(1) {
		t.Fatalf("开口次数不符: today=%v total=%v", today["utterances"], body["total_utterances"])
	}
	week, _ := body["week"].([]any)
	if len(week) != 7 {
		t.Fatalf("最近 7 天应为 7 条，得到 %d", len(week))
	}
	if body["streak_days"] != float64(1) {
		t.Fatalf("连续天数应为 1，得到 %v", body["streak_days"])
	}

	// 结束页（服务端会话星星为准，传 0 也能结算出本轮实际拿到的星星）
	w = do(t, r, nethttp.MethodPost, "/child/anan/bye", map[string]any{
		"role_id": "peppa", "stars": 0, "session_id": "sess-http",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("结束页失败: %d %s", w.Code, w.Body.String())
	}
	if reply, _ := decodeJSON(t, w)["reply_text"].(string); !strings.Contains(reply, strconv.Itoa(int(wantStars))+" 颗小星星") {
		t.Fatalf("结束语应包含服务端结算的星星，得到 %q", reply)
	}

	// 不存在的宝宝
	if w := do(t, r, nethttp.MethodGet, "/child/nobody/stats", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("不存在宝宝统计应返回 404，得到 %d", w.Code)
	}
	if w := do(t, r, nethttp.MethodPost, "/child/nobody/bye", map[string]any{"role_id": "peppa"}); w.Code != nethttp.StatusNotFound {
		t.Fatalf("不存在宝宝结束页应返回 404，得到 %d", w.Code)
	}
}

func TestChatMissingRole(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodPost, "/child/anan/chat", map[string]any{"text": "hi"})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("缺 role_id 应返回 400，得到 %d", w.Code)
	}
}

func TestRoleGreetingUnknownRole(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodGet, "/roles/nobody/greet", nil)
	if w.Code != nethttp.StatusNotFound {
		t.Fatalf("未知角色的语音应返回 404，得到 %d，body=%s", w.Code, w.Body.String())
	}
}

func TestRoleGreetingWithoutTTS(t *testing.T) {
	// 测试环境 TTS 未配置密钥：接口应返回 503，客户端据此静默跳过语音
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodGet, "/roles/peppa/greet", nil)
	if w.Code != nethttp.StatusServiceUnavailable {
		t.Fatalf("TTS 未配置时应返回 503，得到 %d，body=%s", w.Code, w.Body.String())
	}
}

func TestChatEmptyInput(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodPost, "/child/anan/chat", map[string]any{
		"role_id": "peppa", "text": "",
	})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("空输入应返回 400，得到 %d", w.Code)
	}
}

func TestChildRequiresEnglishName(t *testing.T) {
	r := newTestRouter(t)

	w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "ming", "name": "小明",
	})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("缺英文名应返回 400，得到 %d: %s", w.Code, w.Body.String())
	}

	w = do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "ming", "name": "小明", "en_name": "   ",
	})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("空白英文名应返回 400，得到 %d", w.Code)
	}

	w = do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "ming", "name": "小明", "en_name": "Ming",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("英文名合法时应返回 200，得到 %d: %s", w.Code, w.Body.String())
	}
}

func TestTokenAuth(t *testing.T) {
	const token = "test-secret-token"
	r := newTestRouterWithToken(t, token)

	// healthz 免鉴权，供反代 / 负载均衡探活
	if w := do(t, r, nethttp.MethodGet, "/healthz", nil); w.Code != nethttp.StatusOK {
		t.Fatalf("healthz 应免鉴权，得到 %d", w.Code)
	}

	// 不带 token
	if w := do(t, r, nethttp.MethodGet, "/roles", nil); w.Code != nethttp.StatusUnauthorized {
		t.Fatalf("无 token 应返回 401，得到 %d", w.Code)
	}

	// 错误 token
	if w := doWithToken(t, r, nethttp.MethodGet, "/roles", nil, "wrong"); w.Code != nethttp.StatusUnauthorized {
		t.Fatalf("错误 token 应返回 401，得到 %d", w.Code)
	}

	// 正确 token
	if w := doWithToken(t, r, nethttp.MethodGet, "/roles", nil, token); w.Code != nethttp.StatusOK {
		t.Fatalf("正确 token 应返回 200，得到 %d", w.Code)
	}

	// 兼容 Authorization: Bearer
	req := httptest.NewRequest(nethttp.MethodGet, "/roles", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("Bearer token 应返回 200，得到 %d", w.Code)
	}
}

func TestPinFlow(t *testing.T) {
	r := newTestRouter(t)

	// 未设置 PIN
	w := do(t, r, nethttp.MethodPost, "/parent/verify", map[string]any{"pin": "1234"})
	body := decodeJSON(t, w)
	if body["ok"] != false {
		t.Fatalf("未设置 PIN 时 verify 应返回 ok=false，得到 %v", body)
	}

	// 设置 PIN
	w = do(t, r, nethttp.MethodPost, "/parent/pin", map[string]any{"pin": "1234"})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("设置 PIN 状态码应为 200，得到 %d", w.Code)
	}

	// 校验正确
	w = do(t, r, nethttp.MethodPost, "/parent/verify", map[string]any{"pin": "1234"})
	if body := decodeJSON(t, w); body["ok"] != true {
		t.Fatalf("正确 PIN 应返回 ok=true，得到 %v", body)
	}

	// 校验错误
	w = do(t, r, nethttp.MethodPost, "/parent/verify", map[string]any{"pin": "0000"})
	if body := decodeJSON(t, w); body["ok"] != false {
		t.Fatalf("错误 PIN 应返回 ok=false，得到 %v", body)
	}

	// PIN 过短
	w = do(t, r, nethttp.MethodPost, "/parent/pin", map[string]any{"pin": "12"})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("过短 PIN 应返回 400，得到 %d", w.Code)
	}
}

func TestDailyGreetingEndpoint(t *testing.T) {
	r := newTestRouter(t)

	// 宝宝不存在 → 404
	if w := do(t, r, nethttp.MethodGet, "/child/nobody/daily-greeting/peppa", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("宝宝不存在应返回 404，得到 %d", w.Code)
	}

	// 建宝宝
	w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "anan", "name": "安安", "en_name": "Anan", "age": 4, "preferences": "恐龙",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("创建宝宝失败: %d %s", w.Code, w.Body.String())
	}

	// 当天第一次：is_new=true 且有文本
	first := do(t, r, nethttp.MethodGet, "/child/anan/daily-greeting/peppa", nil)
	if first.Code != nethttp.StatusOK {
		t.Fatalf("今日话题应返回 200，得到 %d %s", first.Code, first.Body.String())
	}
	body := decodeJSON(t, first)
	text, _ := body["text"].(string)
	if text == "" {
		t.Fatal("今日话题文本不应为空")
	}
	if body["is_new"] != true {
		t.Fatalf("首次生成 is_new 应为 true，得到 %v", body["is_new"])
	}

	// 第二次：复用同一句，is_new=false
	second := do(t, r, nethttp.MethodGet, "/child/anan/daily-greeting/peppa", nil)
	body2 := decodeJSON(t, second)
	if body2["text"] != text {
		t.Fatalf("当天应复用同一句: %q vs %q", body2["text"], text)
	}
	if body2["is_new"] != false {
		t.Fatalf("当天第二次 is_new 应为 false，得到 %v", body2["is_new"])
	}

	// 未知角色 → 404
	if w := do(t, r, nethttp.MethodGet, "/child/anan/daily-greeting/nobody", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("未知角色应返回 404，得到 %d", w.Code)
	}
}

func TestMessagesEndpoint(t *testing.T) {
	r := newTestRouter(t)

	w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "anan", "name": "安安", "en_name": "Anan",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("创建宝宝失败: %d %s", w.Code, w.Body.String())
	}

	// 没聊过：返回空数组（不是 null），方便客户端直接遍历
	w = do(t, r, nethttp.MethodGet, "/child/anan/messages?role_id=peppa", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("历史消息应返回 200，得到 %d %s", w.Code, w.Body.String())
	}
	body := decodeJSON(t, w)
	list, ok := body["messages"].([]any)
	if !ok || len(list) != 0 {
		t.Fatalf("没聊过时应返回空数组，得到 %v", body["messages"])
	}

	// 两轮对话
	for _, text := range []string{"I like dinosaurs", "Let's sing"} {
		if w := do(t, r, nethttp.MethodPost, "/child/anan/chat", map[string]any{
			"role_id": "peppa", "text": text, "session_id": "s1",
		}); w.Code != nethttp.StatusOK {
			t.Fatalf("对话失败: %d %s", w.Code, w.Body.String())
		}
	}

	// 再次进入：拿到 4 条，按时间正序，宝宝说的在前
	w = do(t, r, nethttp.MethodGet, "/child/anan/messages?role_id=peppa", nil)
	list = decodeJSON(t, w)["messages"].([]any)
	if len(list) != 4 {
		t.Fatalf("两轮对话应有 4 条消息，得到 %d", len(list))
	}
	first := list[0].(map[string]any)
	if first["speaker"] != "child" || first["content"] != "I like dinosaurs" {
		t.Fatalf("第一条应为宝宝说的首句，得到 %v", first)
	}
	last := list[3].(map[string]any)
	if last["speaker"] != "ai" || last["content"] == "" {
		t.Fatalf("最后一条应为 AI 回复，得到 %v", last)
	}

	// limit 取最近 N 条，并告知还有更早的
	w = do(t, r, nethttp.MethodGet, "/child/anan/messages?role_id=peppa&limit=2", nil)
	page := decodeJSON(t, w)
	list = page["messages"].([]any)
	if len(list) != 2 {
		t.Fatalf("limit=2 应返回 2 条，得到 %d", len(list))
	}
	if page["has_more"] != true {
		t.Fatalf("还有更早的消息时 has_more 应为 true，得到 %v", page["has_more"])
	}
	if list[1].(map[string]any)["content"] != service.MockReply("Let's sing") {
		t.Fatalf("最近一页最后一条应是最后一次回复，得到 %v", list[1])
	}

	// 上滑加载更早一页：用当前最早一条的 id 作为 before_id
	oldestID := int64(list[0].(map[string]any)["id"].(float64))
	w = do(t, r, nethttp.MethodGet,
		"/child/anan/messages?role_id=peppa&limit=2&before_id="+strconv.FormatInt(oldestID, 10), nil)
	page = decodeJSON(t, w)
	older := page["messages"].([]any)
	if len(older) != 2 {
		t.Fatalf("更早一页应有 2 条，得到 %d", len(older))
	}
	if older[0].(map[string]any)["content"] != "I like dinosaurs" {
		t.Fatalf("更早一页第一条应是首句，得到 %v", older[0])
	}
	if page["has_more"] != false {
		t.Fatalf("没有更早消息时 has_more 应为 false，得到 %v", page["has_more"])
	}

	// 角色隔离：没聊过的角色查不到
	w = do(t, r, nethttp.MethodGet, "/child/anan/messages?role_id=nobody", nil)
	if list = decodeJSON(t, w)["messages"].([]any); len(list) != 0 {
		t.Fatalf("不同角色不应串消息，得到 %d 条", len(list))
	}

	// 缺 role_id → 400
	if w := do(t, r, nethttp.MethodGet, "/child/anan/messages", nil); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("缺 role_id 应返回 400，得到 %d", w.Code)
	}

	// 重播历史消息语音：按消息 ID 取，避免历史接口返回一大堆 base64
	aiID := strconv.FormatInt(int64(last["id"].(float64)), 10)
	if w := do(t, r, nethttp.MethodGet, "/child/anan/messages/"+aiID+"/audio", nil); w.Code != nethttp.StatusServiceUnavailable {
		t.Fatalf("TTS 未配置时应返回 503 让客户端静默跳过，得到 %d %s", w.Code, w.Body.String())
	}
	childMsgID := strconv.FormatInt(int64(first["id"].(float64)), 10)
	if w := do(t, r, nethttp.MethodGet, "/child/anan/messages/"+childMsgID+"/audio", nil); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("宝宝自己的消息不能重播，应返回 400，得到 %d", w.Code)
	}
	if w := do(t, r, nethttp.MethodGet, "/child/anan/messages/999999/audio", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("不存在的消息应返回 404，得到 %d", w.Code)
	}
	if w := do(t, r, nethttp.MethodGet, "/child/anan/messages/abc/audio", nil); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("非法 message_id 应返回 400，得到 %d", w.Code)
	}
	// 别的宝宝不能播这条消息
	if w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "bob", "name": "波波", "en_name": "Bob",
	}); w.Code != nethttp.StatusOK {
		t.Fatalf("创建第二个宝宝失败: %d %s", w.Code, w.Body.String())
	}
	if w := do(t, r, nethttp.MethodGet, "/child/bob/messages/"+aiID+"/audio", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("跨宝宝重播应返回 404，得到 %d", w.Code)
	}
}

func TestAppReleaseEndpoints(t *testing.T) {
	dir := t.TempDir()
	r := newTestRouterWithRelease(t, "", dir)

	// 还没发布过版本：404，客户端视为无更新
	if w := do(t, r, nethttp.MethodGet, "/app/latest", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("没有版本信息时应返回 404，得到 %d %s", w.Code, w.Body.String())
	}

	// 放一个假 APK + latest.json
	apk := []byte("fake-apk-bytes")
	name := "piggy-pal-1.0.1-2.apk"
	if err := os.WriteFile(filepath.Join(dir, name), apk, 0o644); err != nil {
		t.Fatalf("写假 APK: %v", err)
	}
	rel := model.AppRelease{
		VersionCode: 2,
		VersionName: "1.0.1",
		APKURL:      "/app/download/" + name,
		Size:        int64(len(apk)),
		SHA256:      "abc",
		Changelog:   "支持自动更新",
	}
	b, _ := json.Marshal(rel)
	if err := os.WriteFile(filepath.Join(dir, "latest.json"), b, 0o644); err != nil {
		t.Fatalf("写 latest.json: %v", err)
	}

	w := do(t, r, nethttp.MethodGet, "/app/latest", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("版本信息应返回 200，得到 %d %s", w.Code, w.Body.String())
	}
	got := decodeJSON(t, w)
	if got["version_code"] != float64(2) || got["version_name"] != "1.0.1" ||
		got["apk_url"] != "/app/download/"+name || got["changelog"] != "支持自动更新" {
		t.Fatalf("版本信息字段不对: %v", got)
	}

	// APK 下载：内容一致
	w = do(t, r, nethttp.MethodGet, "/app/download/"+name, nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("下载 APK 应返回 200，得到 %d %s", w.Code, w.Body.String())
	}
	if !bytes.Equal(w.Body.Bytes(), apk) {
		t.Fatalf("下载内容不一致: %q", w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/vnd.android.package-archive" {
		t.Fatalf("Content-Type 不对: %s", ct)
	}

	// 只允许 releases 下的 .apk
	if w := do(t, r, nethttp.MethodGet, "/app/download/latest.json", nil); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("非 apk 文件应返回 400，得到 %d", w.Code)
	}
	if w := do(t, r, nethttp.MethodGet, "/app/download/nope.apk", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("不存在的 APK 应返回 404，得到 %d", w.Code)
	}
}

func TestTimeWarning(t *testing.T) {
	r := newTestRouter(t)

	// 两个节点都要有文案，且带上角色名
	for _, kind := range []string{"2min", "30s"} {
		w := do(t, r, nethttp.MethodGet, "/roles/peppa/time-warning?kind="+kind, nil)
		if w.Code != nethttp.StatusOK {
			t.Fatalf("%s 应返回 200，得到 %d，body=%s", kind, w.Code, w.Body.String())
		}
		var resp model.TimeWarningResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("解析响应失败: %v", err)
		}
		if resp.Kind != kind || resp.Text == "" {
			t.Fatalf("响应不完整: %+v", resp)
		}
		if !strings.Contains(resp.Text, "佩奇") {
			t.Fatalf("提醒文案应带角色名: %s", resp.Text)
		}
	}

	// kind 只能是白名单里的两个，避免被当成任意文本 TTS
	if w := do(t, r, nethttp.MethodGet, "/roles/peppa/time-warning?kind=evil", nil); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("非法 kind 应返回 400，得到 %d", w.Code)
	}
	// 未知角色
	if w := do(t, r, nethttp.MethodGet, "/roles/nobody/time-warning?kind=2min", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("未知角色应返回 404，得到 %d", w.Code)
	}
}

func TestChatStreamStages(t *testing.T) {
	r := newTestRouter(t)
	w := do(t, r, nethttp.MethodPost, "/child/anan/chat/stream", map[string]any{
		"role_id": "peppa", "text": "hello", "session_id": "sess_anan_peppa",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("流式对话应返回 200，得到 %d body=%s", w.Code, w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("Content-Type 应为 text/event-stream，得到 %s", ct)
	}

	body := w.Body.String()
	// 阶段顺序必须是 asr → reply；测试环境 TTS 未配置，所以没有 audio
	asr := strings.Index(body, "event: asr")
	reply := strings.Index(body, "event: reply")
	if asr < 0 || reply < 0 || asr > reply {
		t.Fatalf("事件顺序不对：\n%s", body)
	}
	if !strings.Contains(body, `"child_text":"hello"`) {
		t.Fatalf("asr 事件应带识别文本：\n%s", body)
	}
	if !strings.Contains(body, `"reply_text":`) {
		t.Fatalf("reply 事件应带回复文本：\n%s", body)
	}
	if strings.Contains(body, "event: audio") {
		t.Fatalf("TTS 未配置时不应有 audio 事件：\n%s", body)
	}
}

func TestChatStreamRejectsBadInput(t *testing.T) {
	r := newTestRouter(t)
	// 未知角色
	if w := do(t, r, nethttp.MethodPost, "/child/anan/chat/stream", map[string]any{
		"role_id": "nobody", "text": "hi",
	}); w.Code != nethttp.StatusNotFound {
		t.Fatalf("未知角色应返回 404，得到 %d", w.Code)
	}
	// 空输入
	if w := do(t, r, nethttp.MethodPost, "/child/anan/chat/stream", map[string]any{
		"role_id": "peppa",
	}); w.Code != nethttp.StatusBadRequest {
		t.Fatalf("空输入应返回 400，得到 %d", w.Code)
	}
}

func TestLookupWordEndpoint(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })
	if err := st.UpsertChild(&model.Child{ChildID: "anan", FamilyID: "default", Name: "安安"}); err != nil {
		t.Fatal(err)
	}
	msg := &model.ChatMessage{ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look, a dinosaur!\n看，一只恐龙！"}
	if err := st.SaveMessage(msg); err != nil {
		t.Fatal(err)
	}

	roles := &config.RolesConfig{Roles: []config.Role{{RoleID: "peppa", Name: "佩奇", VoiceID: "101001"}}}
	chat := service.NewChatService(st, service.NewLLMService("", "", ""),
		service.NewTTSService("", "", "", t.TempDir()), service.NewASRService("", "", "", ""),
		service.NewGuardService(nil), roles, &config.PromptsConfig{})
	r := NewRouter(st, roles, chat, "", t.TempDir(), t.TempDir(), "", NewHealth())

	w := do(t, r, nethttp.MethodGet, "/child/anan/dict/dinosaurs?msg_id="+strconv.FormatInt(msg.ID, 10), nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("状态码 = %d, body=%s", w.Code, w.Body.String())
	}
	body := decodeJSON(t, w)
	if body["found"] != true || body["lemma"] != "dinosaur" || body["level"] != "kid" {
		t.Fatalf("响应 = %v", body)
	}
	if body["phonetic_us"] == "" {
		t.Error("缺少音标")
	}
	if audio, _ := body["audio_b64"].(string); audio == "" {
		t.Error("缺少真人发音")
	}
	if slow, _ := body["audio_slow_b64"].(string); slow == "" {
		t.Error("缺少慢读发音")
	}
	if body["audio_source"] != "human" {
		t.Errorf("audio_source = %v", body["audio_source"])
	}
	ctx, _ := body["context"].(map[string]any)
	if ctx == nil || ctx["en"] != "Look, a dinosaur!" {
		t.Errorf("context = %v", body["context"])
	}

	// 缩写不是可查询的词
	w = do(t, r, nethttp.MethodGet, "/child/anan/dict/don%27t", nil)
	if w.Code != nethttp.StatusBadRequest {
		t.Errorf("don't 状态码 = %d, want 400", w.Code)
	}

	// 不存在的宝宝仍然是 404
	w = do(t, r, nethttp.MethodGet, "/child/nobody/dict/apple", nil)
	if w.Code != nethttp.StatusNotFound {
		t.Errorf("不存在的宝宝状态码 = %d, want 404", w.Code)
	}
}
