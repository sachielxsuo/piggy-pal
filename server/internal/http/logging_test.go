package http

import (
	"bytes"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// 访问日志和 handler 内的错误日志都要带 client_id / child_id，
// 否则线上看到一行报错也不知道是哪台手机触发的。
func TestAccessLogCarriesClientAndChildID(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(NewContextHandler(slog.NewTextHandler(&buf, nil))))
	t.Cleanup(func() { slog.SetDefault(old) })

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(requestContext(), accessLog())
	r.GET("/child/:child_id/stats", func(c *gin.Context) {
		// handler 内的日志也要自动带上上下文
		slog.WarnContext(c.Request.Context(), "统计读取失败")
		c.Status(http.StatusInternalServerError)
	})

	req := httptest.NewRequest(http.MethodGet, "/child/hb1/stats", nil)
	req.Header.Set("X-Client-Id", "a_1111222233334444")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	out := buf.String()
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("应输出访问日志 + handler 日志两行，得到 %d 行：\n%s", len(lines), out)
	}
	for _, line := range lines {
		if !strings.Contains(line, "client_id=a_1111222233334444") {
			t.Fatalf("日志缺少 client_id：%s", line)
		}
		if !strings.Contains(line, "child_id=hb1") {
			t.Fatalf("日志缺少 child_id：%s", line)
		}
	}
	if !strings.Contains(out, "msg=http") || !strings.Contains(out, "status=500") {
		t.Fatalf("访问日志字段不完整：\n%s", out)
	}
	if !strings.Contains(out, "level=ERROR") {
		t.Fatalf("5xx 应记为 ERROR 级别：\n%s", out)
	}
	if !strings.Contains(out, "msg=统计读取失败") {
		t.Fatalf("handler 日志内容不对：\n%s", out)
	}
}

// 非法 client_id 不能写进日志，避免日志注入 / 伪造设备。
func TestAccessLogIgnoresUnsafeClientID(t *testing.T) {
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(NewContextHandler(slog.NewTextHandler(&buf, nil))))
	t.Cleanup(func() { slog.SetDefault(old) })

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(requestContext(), accessLog())
	r.GET("/healthz", func(c *gin.Context) { c.Status(http.StatusOK) })

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	req.Header.Set("X-Client-Id", "../../etc/passwd")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if out := buf.String(); strings.Contains(out, "client_id") {
		t.Fatalf("非法 client_id 不应出现在日志里：%s", out)
	}
}
