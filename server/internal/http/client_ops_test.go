package http

import (
	"bytes"
	"encoding/json"
	"errors"
	nethttp "net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/gin-gonic/gin"
)

const testClientID = "c_0123456789abcdef0123456789abcdef"

// doAdmin 带运维管理令牌发请求。
func doAdmin(t *testing.T, r *gin.Engine, method, path string, body any, adminToken string) *httptest.ResponseRecorder {
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
	if adminToken != "" {
		req.Header.Set("X-Admin-Token", adminToken)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func heartbeatBody(clientID, childID, runID string, durationSec int) map[string]any {
	return map[string]any{
		"client_id":   clientID,
		"label":       "android 15 (SDK 35)",
		"platform":    "android",
		"app_version": "1.0.4 (5)",
		"session": map[string]any{
			"child_id":     childID,
			"session_id":   "sess_" + childID + "_peppa",
			"run_id":       runID,
			"duration_sec": durationSec,
		},
	}
}

func todayDuration(t *testing.T, r *gin.Engine, childID string) (int, int) {
	t.Helper()
	w := do(t, r, nethttp.MethodGet, "/child/"+childID+"/stats", nil)
	if w.Code != nethttp.StatusOK {
		t.Fatalf("stats 状态码 %d: %s", w.Code, w.Body.String())
	}
	today, _ := decodeJSON(t, w)["today"].(map[string]any)
	sec, _ := today["duration_sec"].(float64)
	openCount, _ := today["open_count"].(float64)
	return int(sec), int(openCount)
}

// 心跳里的时长是累计值，重复 / 乱序上报都必须幂等。
func TestHeartbeatDurationIsIdempotent(t *testing.T) {
	r := newTestRouterWithAdmin(t, "", t.TempDir(), "adm")
	if w := do(t, r, nethttp.MethodPost, "/child", map[string]any{
		"child_id": "hb1", "name": "豆豆", "en_name": "Doudou", "age": 4,
	}); w.Code != nethttp.StatusOK {
		t.Fatalf("创建宝宝失败: %d %s", w.Code, w.Body.String())
	}

	beat := func(sec int) map[string]any {
		w := do(t, r, nethttp.MethodPost, "/client/heartbeat", heartbeatBody(testClientID, "hb1", "run_1", sec))
		if w.Code != nethttp.StatusOK {
			t.Fatalf("心跳 %ds 失败: %d %s", sec, w.Code, w.Body.String())
		}
		return decodeJSON(t, w)
	}

	// 第一次 30s：计入 30 秒 + 1 次打开
	beat(30)
	if sec, opens := todayDuration(t, r, "hb1"); sec != 30 || opens != 1 {
		t.Fatalf("首次上报后应为 30s / 1 次打开，得到 %ds / %d", sec, opens)
	}

	// 同一次上报重试（网络重发）：不能重复加
	beat(30)
	beat(30)
	if sec, opens := todayDuration(t, r, "hb1"); sec != 30 || opens != 1 {
		t.Fatalf("重复上报不应累加，得到 %ds / %d", sec, opens)
	}

	// 时间推进：只补差额
	beat(60)
	if sec, opens := todayDuration(t, r, "hb1"); sec != 60 || opens != 1 {
		t.Fatalf("推进到 60s 后应为 60s / 1 次打开，得到 %ds / %d", sec, opens)
	}

	// 乱序（旧快照晚到）：不能回退也不能重复加
	beat(45)
	if sec, _ := todayDuration(t, r, "hb1"); sec != 60 {
		t.Fatalf("旧快照不应让时长回退，得到 %ds", sec)
	}

	// 新的一次运行：时长继续累加，打开次数 +1
	beat2 := do(t, r, nethttp.MethodPost, "/client/heartbeat", heartbeatBody(testClientID, "hb1", "run_2", 20))
	if beat2.Code != nethttp.StatusOK {
		t.Fatalf("第二次运行心跳失败: %d %s", beat2.Code, beat2.Body.String())
	}
	if sec, opens := todayDuration(t, r, "hb1"); sec != 80 || opens != 2 {
		t.Fatalf("第二次运行后应为 80s / 2 次打开，得到 %ds / %d", sec, opens)
	}
}

// 心跳顺手把服务端指令带下去，客户端 ack 后不再重复下发。
func TestClientCommandDeliveredOnce(t *testing.T) {
	r := newTestRouterWithAdmin(t, "", t.TempDir(), "adm")

	// 先心跳一次登记设备
	beat := func() []any {
		w := do(t, r, nethttp.MethodPost, "/client/heartbeat", map[string]any{
			"client_id": testClientID, "label": "android 15", "platform": "android", "app_version": "1.0.4 (5)",
		})
		if w.Code != nethttp.StatusOK {
			t.Fatalf("心跳失败: %d %s", w.Code, w.Body.String())
		}
		cmds, _ := decodeJSON(t, w)["commands"].([]any)
		return cmds
	}
	if cmds := beat(); len(cmds) != 0 {
		t.Fatalf("还没发指令时不应有下发: %v", cmds)
	}

	// 设备列表里能看到它
	w := doAdmin(t, r, nethttp.MethodGet, "/admin/clients", nil, "adm")
	clients, _ := decodeJSON(t, w)["clients"].([]any)
	if len(clients) != 1 {
		t.Fatalf("设备列表应有 1 台，得到 %v", clients)
	}

	// 下发「提取客户端日志」
	w = doAdmin(t, r, nethttp.MethodPost, "/admin/clients/"+testClientID+"/commands",
		map[string]any{"type": "upload_logs"}, "adm")
	if w.Code != nethttp.StatusOK {
		t.Fatalf("下发指令失败: %d %s", w.Code, w.Body.String())
	}
	cmd := decodeJSON(t, w)["command"].(map[string]any)
	cmdID := int64(cmd["id"].(float64))

	// 下一次心跳拿到它
	cmds := beat()
	if len(cmds) != 1 {
		t.Fatalf("应下发 1 条指令，得到 %v", cmds)
	}
	got := cmds[0].(map[string]any)
	if got["type"] != "upload_logs" || int64(got["id"].(float64)) != cmdID {
		t.Fatalf("指令内容不对: %v", got)
	}

	// ack 后不再下发
	if w := do(t, r, nethttp.MethodPost, "/client/commands/"+itoa(cmdID)+"/ack",
		map[string]any{"client_id": testClientID, "ok": true, "result": "uploaded 1 file"},
	); w.Code != nethttp.StatusOK {
		t.Fatalf("ack 失败: %d %s", w.Code, w.Body.String())
	}
	if cmds := beat(); len(cmds) != 0 {
		t.Fatalf("ack 之后不应再下发: %v", cmds)
	}

	// 结果可查
	w = doAdmin(t, r, nethttp.MethodGet, "/admin/clients/"+testClientID+"/commands", nil, "adm")
	list, _ := decodeJSON(t, w)["commands"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["status"] != "done" {
		t.Fatalf("指令状态应为 done，得到 %v", list)
	}
}

// 管理接口在没配置令牌时整体关闭，配了则必须带对令牌。
func TestAdminAuth(t *testing.T) {
	closed := newTestRouterWithAdmin(t, "", t.TempDir(), "")
	if w := do(t, closed, nethttp.MethodGet, "/admin/clients", nil); w.Code != nethttp.StatusNotFound {
		t.Fatalf("未配置 ADMIN_TOKEN 时应 404，得到 %d", w.Code)
	}

	r := newTestRouterWithAdmin(t, "", t.TempDir(), "adm")
	if w := do(t, r, nethttp.MethodGet, "/admin/clients", nil); w.Code != nethttp.StatusUnauthorized {
		t.Fatalf("缺少管理令牌应 401，得到 %d", w.Code)
	}
	if w := doAdmin(t, r, nethttp.MethodGet, "/admin/clients", nil, "bad"); w.Code != nethttp.StatusUnauthorized {
		t.Fatalf("错误管理令牌应 401，得到 %d", w.Code)
	}
	if w := doAdmin(t, r, nethttp.MethodGet, "/admin/clients", nil, "adm"); w.Code != nethttp.StatusOK {
		t.Fatalf("正确令牌应 200，得到 %d", w.Code)
	}
}

// 不同设备上传的日志必须落在各自目录，互不覆盖。
func TestClientLogIsolation(t *testing.T) {
	dir := t.TempDir()
	r := newTestRouterFull(t, "", dir, t.TempDir(), "adm")

	for _, id := range []string{"c_aaaaaaaaaaaaaaaa", "c_bbbbbbbbbbbbbbbb"} {
		w := do(t, r, nethttp.MethodPost, "/client-logs", map[string]any{
			"client_id": id,
			"filename":  "2026-10-25_09-00-00.log",
			"content":   "hello from " + id,
		})
		if w.Code != nethttp.StatusOK {
			t.Fatalf("上传日志失败: %d %s", w.Code, w.Body.String())
		}
		if got := decodeJSON(t, w)["path"].(string); filepath.Dir(got) != filepath.Join(dir, id) {
			t.Fatalf("日志目录未按 client 隔离: %s", got)
		}
	}

	for _, id := range []string{"c_aaaaaaaaaaaaaaaa", "c_bbbbbbbbbbbbbbbb"} {
		if _, err := os.Stat(filepath.Join(dir, id, "2026-10-25_09-00-00.log")); err != nil {
			t.Fatalf("设备 %s 的日志文件不存在: %v", id, err)
		}
	}

	// 非法 client_id（带路径穿越）直接拒绝
	w := do(t, r, nethttp.MethodPost, "/client-logs", map[string]any{
		"client_id": "../../etc", "filename": "x.log", "content": "boom",
	})
	if w.Code != nethttp.StatusBadRequest {
		t.Fatalf("非法 client_id 应 400，得到 %d", w.Code)
	}

	// 旧版本不传 client_id：归到 _legacy，不散落在根目录
	w = do(t, r, nethttp.MethodPost, "/client-logs", map[string]any{
		"filename": "legacy.log", "content": "old client",
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("旧客户端上传应兼容，得到 %d", w.Code)
	}
	if _, err := os.Stat(filepath.Join(dir, "_legacy", "legacy.log")); err != nil {
		t.Fatalf("旧客户端日志应落到 _legacy/: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "legacy.log")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("根目录不应再出现日志文件: %v", err)
	}
}

// 「关于」页手动上传和服务端指令提取走的是同一个接口，
// 这里验证两条路径产出的文件都落在各自 client 目录、同名也不互相覆盖。
func TestClientLogManualAndCommandUploadsStayIsolated(t *testing.T) {
	dir := t.TempDir()
	r := newTestRouterFull(t, "", dir, t.TempDir(), "adm")

	const deviceA = "a_1111222233334444"
	const deviceB = "a_5555666677778888"

	// 手动上传：文件名 = 日志起始时间
	manual := map[string]any{
		"filename": "2026-10-25_09-27-24.log", "content": "manual from A",
	}
	// 指令提取：文件名带 cmd 前缀和命令号
	cmd := map[string]any{
		"filename": "cmd-1-2026-10-25_09-27-24.log", "content": "command from A",
	}
	for _, body := range []map[string]any{manual, cmd} {
		body["client_id"] = deviceA
		if w := do(t, r, nethttp.MethodPost, "/client-logs", body); w.Code != nethttp.StatusOK {
			t.Fatalf("上传失败: %d %s", w.Code, w.Body.String())
		}
	}
	// B 也有一份同名的手动上传
	if w := do(t, r, nethttp.MethodPost, "/client-logs", map[string]any{
		"client_id": deviceB, "filename": manual["filename"], "content": "manual from B",
	}); w.Code != nethttp.StatusOK {
		t.Fatalf("B 上传失败: %d %s", w.Code, w.Body.String())
	}

	checks := []struct{ client, name, want string }{
		{deviceA, "2026-10-25_09-27-24.log", "manual from A"},
		{deviceA, "cmd-1-2026-10-25_09-27-24.log", "command from A"},
		{deviceB, "2026-10-25_09-27-24.log", "manual from B"},
	}
	for _, c := range checks {
		b, err := os.ReadFile(filepath.Join(dir, c.client, c.name))
		if err != nil {
			t.Fatalf("设备 %s 的 %s 不存在: %v", c.client, c.name, err)
		}
		if string(b) != c.want {
			t.Fatalf("设备 %s 的 %s 内容串了: %q", c.client, c.name, b)
		}
	}
}

func itoa(v int64) string { return strconv.FormatInt(v, 10) }

// 心跳要顺带下发「有新版本」：客户端据此亮红点 + 弹一次提示，不自动更新。
func TestHeartbeatCarriesAppUpdate(t *testing.T) {
	relDir := t.TempDir()
	const latest = `{"version_code":7,"version_name":"1.0.6","apk_url":"/app/download/piggy-pal-1.0.6-7.apk","size":21300000,"sha256":"abc","changelog":"修复若干问题","force":false}`
	if err := os.WriteFile(filepath.Join(relDir, "latest.json"), []byte(latest), 0o644); err != nil {
		t.Fatalf("写 latest.json 失败: %v", err)
	}
	r := newTestRouterWithAdmin(t, "", relDir, "adm")

	beat := func(versionCode int) map[string]any {
		w := do(t, r, nethttp.MethodPost, "/client/heartbeat", map[string]any{
			"client_id": testClientID, "label": "android 15", "platform": "android",
			"app_version": "1.0.5 (6)", "version_code": versionCode,
		})
		if w.Code != nethttp.StatusOK {
			t.Fatalf("心跳失败: %d %s", w.Code, w.Body.String())
		}
		return decodeJSON(t, w)
	}

	// 旧版本：应下发 app_update
	body := beat(6)
	up, ok := body["app_update"].(map[string]any)
	if !ok {
		t.Fatalf("旧版本心跳应带 app_update，得到 %v", body)
	}
	if up["version_name"] != "1.0.6" || int(up["version_code"].(float64)) != 7 {
		t.Fatalf("app_update 内容不对: %v", up)
	}

	// 已是最新 / 比线上还新：不下发
	for _, vc := range []int{7, 8} {
		if body := beat(vc); body["app_update"] != nil {
			t.Fatalf("version_code=%d 不应下发 app_update: %v", vc, body["app_update"])
		}
	}

	// 老客户端不报 version_code（0）：无法判断，宁可不打扰
	if body := beat(0); body["app_update"] != nil {
		t.Fatalf("version_code=0 不应下发 app_update: %v", body["app_update"])
	}
}

// 还没发布过版本（没有 latest.json）时，心跳照常返回、不报错。
func TestHeartbeatWithoutRelease(t *testing.T) {
	r := newTestRouterWithAdmin(t, "", t.TempDir(), "adm")
	w := do(t, r, nethttp.MethodPost, "/client/heartbeat", map[string]any{
		"client_id": testClientID, "version_code": 1,
	})
	if w.Code != nethttp.StatusOK {
		t.Fatalf("心跳失败: %d %s", w.Code, w.Body.String())
	}
	if body := decodeJSON(t, w); body["app_update"] != nil {
		t.Fatalf("没有 latest.json 时不应下发 app_update: %v", body["app_update"])
	}
}
