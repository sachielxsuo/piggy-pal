package http

import (
	"log/slog"
	nethttp "net/http"
	"regexp"
	"strconv"
	"strings"

	"piggy-pal/server/internal/model"

	"github.com/gin-gonic/gin"
)

// client_id 由 App 首次启动生成（32 位 hex + 前缀），只允许安全字符，可直接当目录名。
var clientIDRe = regexp.MustCompile(`^[0-9A-Za-z_-]{8,64}$`)

// 目前支持的服务端指令。新增指令时在这里登记，并在客户端 CommandRunner 里实现。
var allowedCommandTypes = map[string]bool{
	"upload_logs": true, // 提取客户端日志：上传最近 2 小时日志到服务器
}

// heartbeat 客户端每 30 秒一次的心跳：刷新设备信息、上报本次运行累计时长、
// 领取服务端下发的指令。时长上报是幂等的（服务端按 run_id 取 max 补差）。
func (s *Server) heartbeat(c *gin.Context) {
	var req model.HeartbeatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	req.ClientID = strings.TrimSpace(req.ClientID)
	if !clientIDRe.MatchString(req.ClientID) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少或非法的 client_id"})
		return
	}

	if err := s.store.TouchClient(req.ClientID, req.Label, req.Platform, req.AppVersion); err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	if sess := req.Session; sess != nil && sess.RunID != "" && sess.ChildID != "" {
		// 宝宝被删了 / 客户端缓存了旧 id：忽略这一段，不影响心跳和指令
		if child, err := s.store.GetChild(sess.ChildID); err == nil && child != nil {
			if _, err := s.store.ReportRunDuration(
				req.ClientID, sess.RunID, sess.ChildID, sess.SessionID, sess.DurationSec,
			); err != nil {
				c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
				return
			}
		}
	}

	cmds, err := s.store.TakeCommands(req.ClientID, 5)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	resp := gin.H{"ok": true, "commands": cmds}

	// 有新版本就顺手告诉客户端（客户端据此亮红点 + 弹一次提示，不自动更新）。
	// 这里按 versionCode 比对，和自动更新用的是同一份 latest.json。
	// app_update 里带着 min_version_code，客户端低于最低版就弹不可关闭的强制更新窗。
	if rel, err := s.latestRelease(); err == nil && rel != nil && req.VersionCode > 0 {
		if rel.VersionCode > req.VersionCode {
			resp["app_update"] = rel
		}
		// 不硬拦截（老客户端请求里没有版本号，拦不住），只留一条可观测记录：
		// 上线后看这条日志还在不在，就知道强制更新到底有没有生效。
		if rel.MinVersionCode > req.VersionCode {
			slog.WarnContext(c.Request.Context(), "客户端低于最低版本，已下发强制更新",
				"client_id", req.ClientID, "version_code", req.VersionCode,
				"min_version_code", rel.MinVersionCode)
		}
	}
	c.JSON(nethttp.StatusOK, resp)
}

// ackCommand 客户端执行完指令后回执（上传日志成功 / 失败都回执）。
func (s *Server) ackCommand(c *gin.Context) {
	id, err := strconv.ParseInt(c.Param("id"), 10, 64)
	if err != nil || id <= 0 {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "指令 ID 不合法"})
		return
	}
	var req model.CommandAckRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	req.ClientID = strings.TrimSpace(req.ClientID)
	if !clientIDRe.MatchString(req.ClientID) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少或非法的 client_id"})
		return
	}
	if err := s.store.AckCommand(req.ClientID, id, req.OK, req.Result); err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": true})
}

// ===== 管理接口（仅运维用，额外要求 X-Admin-Token） =====

// listClients 最近上报过心跳的设备。
func (s *Server) listClients(c *gin.Context) {
	clients, err := s.store.ListClients()
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"clients": clients})
}

// createCommand 给指定设备下发一条指令。
func (s *Server) createCommand(c *gin.Context) {
	clientID := strings.TrimSpace(c.Param("client_id"))
	if !clientIDRe.MatchString(clientID) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "client_id 不合法"})
		return
	}
	var req struct {
		Type   string `json:"type"`
		Params string `json:"params"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	req.Type = strings.TrimSpace(req.Type)
	if !allowedCommandTypes[req.Type] {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "不支持的指令类型"})
		return
	}
	cmd, err := s.store.CreateCommand(clientID, req.Type, req.Params)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": true, "command": cmd})
}

// listCommands 查看某台设备最近的指令与执行结果。
func (s *Server) listCommands(c *gin.Context) {
	clientID := strings.TrimSpace(c.Param("client_id"))
	if !clientIDRe.MatchString(clientID) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "client_id 不合法"})
		return
	}
	cmds, err := s.store.ListCommands(clientID, 20)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"commands": cmds})
}
