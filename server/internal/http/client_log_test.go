package http

import (
	"bytes"
	"encoding/json"
	nethttp "net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func newClientLogRouter(t *testing.T) (*gin.Engine, string) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	dir := t.TempDir()
	s := &Server{clientLogDir: dir}
	r := gin.New()
	r.POST("/client-logs", s.uploadClientLog)
	return r, dir
}

func postLog(t *testing.T, r *gin.Engine, clientID, filename, content string) *httptest.ResponseRecorder {
	t.Helper()
	body := map[string]string{"filename": filename, "content": content}
	if clientID != "" {
		body["client_id"] = clientID
	}
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(nethttp.MethodPost, "/client-logs", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

func TestUploadClientLog(t *testing.T) {
	r, dir := newClientLogRouter(t)
	const clientID = "a_1111222233334444"
	w := postLog(t, r, clientID, "2026-10-25_09-27-24.log", "line1\nline2\n")
	if w.Code != nethttp.StatusOK {
		t.Fatalf("status = %d, body = %s", w.Code, w.Body.String())
	}

	// 日志按 client_id 分目录，不落在根目录
	path := filepath.Join(dir, clientID, "2026-10-25_09-27-24.log")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read uploaded log: %v", err)
	}
	if string(data) != "line1\nline2\n" {
		t.Fatalf("content = %q", string(data))
	}

	// 同一文件名再传一次：不能覆盖上一个现场，应加序号
	w = postLog(t, r, clientID, "2026-10-25_09-27-24.log", "second")
	if w.Code != nethttp.StatusOK {
		t.Fatalf("second upload status = %d", w.Code)
	}
	if _, err := os.Stat(filepath.Join(dir, clientID, "2026-10-25_09-27-24-2.log")); err != nil {
		t.Fatalf("expected dedup file: %v", err)
	}
}

func TestUploadClientLogRejectsBadInput(t *testing.T) {
	r, _ := newClientLogRouter(t)

	cases := []struct {
		name     string
		filename string
		content  string
	}{
		{"path traversal", "../../etc/passwd", "x"},
		{"empty content", "2026-10-25_09-27-24.log", "   "},
		{"empty filename", "", "x"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := postLog(t, r, "", tc.filename, tc.content)
			if w.Code != nethttp.StatusBadRequest {
				t.Fatalf("status = %d, want 400, body = %s", w.Code, w.Body.String())
			}
		})
	}
}

func TestClientLogNamePattern(t *testing.T) {
	ok := []string{
		"2026-10-25_09-27-24.log",
		"app.log",
		"a",
		"2026-10-25_09-27-24-2.log",
	}
	bad := []string{
		"../x.log",
		"a/b.log",
		"中文.log",
		strings.Repeat("a", 101) + ".log",
	}
	for _, name := range ok {
		if !clientLogNameRe.MatchString(name) {
			t.Errorf("expected valid: %q", name)
		}
	}
	for _, name := range bad {
		if clientLogNameRe.MatchString(name) {
			t.Errorf("expected invalid: %q", name)
		}
	}
}
