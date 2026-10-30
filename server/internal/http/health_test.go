package http

import (
	"context"
	nethttp "net/http"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/service"
	"piggy-pal/server/internal/store"
)

// newTestRouterWithHealth 允许测试自己控制生命周期状态（排空 / 就绪）。
func newTestRouterWithHealth(t *testing.T, token string, health *Health) *gin.Engine {
	t.Helper()
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { st.Close() })

	roles := &config.RolesConfig{Roles: []config.Role{
		{RoleID: "peppa", Name: "佩奇", VoiceID: "101001"},
	}}
	chat := service.NewChatService(st, service.NewLLMService("", "", ""),
		service.NewTTSService("", "", "", t.TempDir()),
		service.NewASRService("", "", "", ""),
		service.NewGuardService(nil), roles, &config.PromptsConfig{})
	return NewRouter(st, roles, chat, token, t.TempDir(), t.TempDir(), "", health)
}

// 发布时两种探针的语义必须分开，否则优雅退出本身会把告警窗口拉长到整个排空时长。
func TestHealthStaysUpWhileDraining(t *testing.T) {
	health := NewHealth()
	r := newTestRouterWithHealth(t, "secret", health)

	// 正常状态：两个都 200
	w := doWithToken(t, r, nethttp.MethodGet, "/healthz", nil, "secret")
	if w.Code != nethttp.StatusOK {
		t.Fatalf("healthz = %d", w.Code)
	}
	if body := decodeJSON(t, w); body["status"] != "ok" || body["service"] != "piggy-pal" {
		t.Fatalf("healthz body = %v（UptimeRobot 关键字依赖这个结构）", body)
	}
	if w := doWithToken(t, r, nethttp.MethodGet, "/readyz", nil, "secret"); w.Code != nethttp.StatusOK {
		t.Fatalf("readyz = %d, body=%s", w.Code, w.Body.String())
	}

	// 进入排空：healthz 仍是 200（进程活着），readyz 变 503（不接新活）
	health.StartDraining()
	if w := doWithToken(t, r, nethttp.MethodGet, "/healthz", nil, "secret"); w.Code != nethttp.StatusOK {
		t.Fatalf("排空期间 healthz 应保持 200，得到 %d", w.Code)
	}
	w = doWithToken(t, r, nethttp.MethodGet, "/readyz", nil, "secret")
	if w.Code != nethttp.StatusServiceUnavailable {
		t.Fatalf("排空期间 readyz 应为 503，得到 %d", w.Code)
	}
	if body := decodeJSON(t, w); body["reason"] != "draining" {
		t.Fatalf("readyz reason = %v", body["reason"])
	}
}

// 探针不能被鉴权拦住：部署脚本和外部监控都不带 token。
func TestProbesSkipTokenAuth(t *testing.T) {
	r := newTestRouterWithHealth(t, "secret", NewHealth())
	for _, path := range []string{"/healthz", "/readyz"} {
		if w := do(t, r, nethttp.MethodGet, path, nil); w.Code == nethttp.StatusUnauthorized {
			t.Fatalf("%s 不应要求 token，得到 401", path)
		}
	}
}

// 排空期间：普通请求拿 503（而不是 connection refused），两个探针照常可达。
func TestDrainingGateRejectsNewWork(t *testing.T) {
	health := NewHealth()
	r := newTestRouterWithHealth(t, "", health)
	health.StartDraining()

	w := do(t, r, nethttp.MethodGet, "/roles", nil)
	if w.Code != nethttp.StatusServiceUnavailable {
		t.Fatalf("排空期间普通请求应为 503，得到 %d", w.Code)
	}
	if w.Header().Get("Retry-After") != "5" {
		t.Fatalf("应带 Retry-After，得到 %q", w.Header().Get("Retry-After"))
	}
	if w := do(t, r, nethttp.MethodGet, "/healthz", nil); w.Code != nethttp.StatusOK {
		t.Fatalf("排空期间 healthz 应为 200，得到 %d", w.Code)
	}
	if n := health.Inflight(); n != 0 {
		t.Fatalf("请求结束后在途数应归零，得到 %d", n)
	}
}

// 在途请求没跑完时不能退出，WaitIdle 要能等到归零。
func TestWaitIdle(t *testing.T) {
	h := NewHealth()
	h.BeginRequest()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if err := h.WaitIdle(ctx); err == nil {
		t.Fatal("还有在途请求时 WaitIdle 应超时")
	}

	h.EndRequest()
	if err := h.WaitIdle(context.Background()); err != nil {
		t.Fatalf("归零后 WaitIdle 应立即返回: %v", err)
	}
}
