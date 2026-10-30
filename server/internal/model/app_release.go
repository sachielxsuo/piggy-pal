package model

// AppRelease 客户端自动更新信息（服务端 data/releases/latest.json）。
type AppRelease struct {
	VersionCode int    `json:"version_code"` // Android versionCode，和本地比大小
	VersionName string `json:"version_name"` // 展示给家长，如 1.0.1
	APKURL      string `json:"apk_url"`      // 相对路径（/app/download/xxx.apk），客户端拼域名
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	Changelog   string `json:"changelog"`
	Force       bool   `json:"force"` // 强制更新：不提供「稍后」
	// MinVersionCode 是允许继续使用的最低 versionCode，低于它的客户端会弹不可关闭的
	// 强制更新窗。0 = 不启用（默认），避免旧 latest.json 或手滑把所有人挡在门外。
	// 服务端会把它夹在 [0, VersionCode] 之间，配错也只会退化成「更新到最新版」。
	MinVersionCode int `json:"min_version_code"`
}
