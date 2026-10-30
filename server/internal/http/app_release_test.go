package http

import (
	nethttp "net/http"
	"os"
	"path/filepath"
	"testing"
)

func writeLatest(t *testing.T, dir, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, "latest.json"), []byte(body), 0o644); err != nil {
		t.Fatalf("write latest.json: %v", err)
	}
}

// min_version_code 是把所有人挡在门外的开关，配错必须能自愈，不能一配就把全家设备锁死。
func TestLatestAppClampsMinVersion(t *testing.T) {
	cases := []struct {
		name string
		json string
		want float64
	}{
		{
			name: "正常值原样下发",
			json: `{"version_code":20,"version_name":"1.0.20","apk_url":"/app/download/a.apk","min_version_code":18}`,
			want: 18,
		},
		{
			name: "比最新版还高：夹到最新版，最多退化成普通更新",
			json: `{"version_code":20,"version_name":"1.0.20","apk_url":"/app/download/a.apk","min_version_code":25}`,
			want: 20,
		},
		{
			name: "负数：当作不启用",
			json: `{"version_code":20,"version_name":"1.0.20","apk_url":"/app/download/a.apk","min_version_code":-3}`,
			want: 0,
		},
		{
			name: "老 latest.json 没有这个字段：默认不强制",
			json: `{"version_code":20,"version_name":"1.0.20","apk_url":"/app/download/a.apk"}`,
			want: 0,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			writeLatest(t, dir, tc.json)
			r := newTestRouterWithRelease(t, "", dir)

			w := do(t, r, nethttp.MethodGet, "/app/latest", nil)
			if w.Code != nethttp.StatusOK {
				t.Fatalf("状态码 = %d, body=%s", w.Code, w.Body.String())
			}
			if got := decodeJSON(t, w)["min_version_code"]; got != tc.want {
				t.Fatalf("min_version_code = %v, want %v", got, tc.want)
			}
		})
	}
}
