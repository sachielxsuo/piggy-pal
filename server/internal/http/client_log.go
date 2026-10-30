package http

import (
	"errors"
	"fmt"
	nethttp "net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/gin-gonic/gin"
)

// 客户端日志上传上限：正常一次 2 小时日志远小于 8MB，超限按坏请求处理。
const maxClientLogBytes = 8 << 20

// 只允许安全文件名（客户端用「起始时间」命名），避免路径穿越。
var clientLogNameRe = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._-]{0,99}$`)

// uploadClientLog 接收 App 上传的运行日志，落盘到独立目录（与 server.log 分开）。
// 文件名由客户端按日志起始时间生成，例如 2026-10-25_09-27-24.log。
func (s *Server) uploadClientLog(c *gin.Context) {
	c.Request.Body = nethttp.MaxBytesReader(c.Writer, c.Request.Body, maxClientLogBytes)

	var req struct {
		Filename string `json:"filename"`
		Content  string `json:"content"`
		// ClientID 由 App 生成并持久化；同一账号可能有多台设备，日志按它分目录隔离，
		// 避免两台手机的日志混在一个目录里。旧版本不传时落到 unknown/。
		ClientID string `json:"client_id"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		var tooLarge *nethttp.MaxBytesError
		if errors.As(err, &tooLarge) {
			c.JSON(nethttp.StatusRequestEntityTooLarge, gin.H{"error": "日志太大啦"})
			return
		}
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}

	name := strings.TrimSpace(req.Filename)
	if !strings.HasSuffix(strings.ToLower(name), ".log") {
		name += ".log"
	}
	if !clientLogNameRe.MatchString(name) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "文件名不合法"})
		return
	}
	if strings.TrimSpace(req.Content) == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "日志内容为空"})
		return
	}

	clientID := strings.TrimSpace(req.ClientID)
	if clientID != "" && !clientIDRe.MatchString(clientID) {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "client_id 不合法"})
		return
	}
	path, err := s.writeClientLog(clientID, name, req.Content)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": "日志保存失败"})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{
		"ok":        true,
		"client_id": clientID,
		"filename":  filepath.Base(path),
		"path":      path,
		"bytes":     len(req.Content),
	})
}

// writeClientLog 原子写入日志文件；同名文件已存在时加序号，避免覆盖历史现场。
// 每台设备的日志落在自己的子目录里（client_id 已校验为安全字符）。
func (s *Server) writeClientLog(clientID, name, content string) (string, error) {
	dir := s.clientLogDir
	if dir == "" {
		return "", errors.New("未配置客户端日志目录")
	}
	// 目录名就是 client_id；没带的旧版本（还没有 client_id）单独归到 _legacy，
	// 不再散落在根目录，保证「一个目录 = 一台设备」。
	sub := clientID
	if sub == "" {
		sub = "_legacy"
	}
	dir = filepath.Join(dir, sub)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); err == nil {
		ext := filepath.Ext(name)
		base := strings.TrimSuffix(name, ext)
		for i := 2; i < 1000; i++ {
			p := filepath.Join(dir, fmt.Sprintf("%s-%d%s", base, i, ext))
			if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
				path = p
				break
			}
		}
	}

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), 0o644); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, path); err != nil {
		return "", err
	}
	return path, nil
}
