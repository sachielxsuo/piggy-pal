package model

// ClientDevice 一台安装了 App 的设备（一个安装实例）。
//
// client_id 由客户端首次启动时生成并持久化在本地，用来把多台设备的
// 心跳、时长、日志、指令隔离开——不能拿 child_id（同一宝宝可以多台设备）
// 或全站共享的 API_TOKEN（所有设备一样）当唯一标识。
type ClientDevice struct {
	ClientID   string `json:"client_id"`
	Label      string `json:"label"`       // 设备可读名，如 android 15 (SDK 35)
	Platform   string `json:"platform"`    // android / ios
	AppVersion string `json:"app_version"` // 如 1.0.4 (5)
	LastSeen   string `json:"last_seen"`
	CreatedAt  string `json:"created_at"`
}

// ClientCommand 服务端下发给某台客户端的指令。
type ClientCommand struct {
	ID          int64  `json:"id"`
	ClientID    string `json:"client_id"`
	Type        string `json:"type"` // 目前只有 upload_logs
	Params      string `json:"params,omitempty"`
	Status      string `json:"status"` // pending / delivered / done / failed
	CreatedAt   string `json:"created_at"`
	DeliveredAt string `json:"delivered_at,omitempty"`
	AckedAt     string `json:"acked_at,omitempty"`
	Result      string `json:"result,omitempty"`
}

// ClientSession 心跳里携带的「本次对话运行」快照，时长是累计值而不是增量。
type ClientSession struct {
	ChildID     string `json:"child_id"`
	SessionID   string `json:"session_id"`
	RunID       string `json:"run_id"`
	DurationSec int    `json:"duration_sec"`
}

// HeartbeatRequest 客户端每 30 秒一次的心跳：上报设备信息 + 本次运行时长，
// 同时领取服务端下发的指令。
type HeartbeatRequest struct {
	ClientID   string `json:"client_id"`
	Label      string `json:"label"`
	Platform   string `json:"platform"`
	AppVersion string `json:"app_version"`
	// VersionCode 客户端当前的 Android versionCode，服务端据此判断要不要下发新版本
	VersionCode int            `json:"version_code"`
	Session     *ClientSession `json:"session"`
}

// CommandAckRequest 客户端执行完指令后回执。
type CommandAckRequest struct {
	ClientID string `json:"client_id"`
	OK       bool   `json:"ok"`
	Result   string `json:"result"`
}
