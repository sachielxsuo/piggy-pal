package http

import (
	"encoding/json"
	"errors"
	"log/slog"
	nethttp "net/http"
	"os"
	"path/filepath"
	"strings"

	"piggy-pal/server/internal/model"

	"github.com/gin-gonic/gin"
)

// latestRelease 读取 data/releases/latest.json。
// 没有发布过版本、或文件不完整时返回 (nil, nil)，调用方按「无更新」处理。
func (s *Server) latestRelease() (*model.AppRelease, error) {
	path := filepath.Join(s.releaseDir, "latest.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var rel model.AppRelease
	if err := json.Unmarshal(data, &rel); err != nil {
		return nil, err
	}
	if rel.VersionCode <= 0 || rel.APKURL == "" {
		return nil, nil
	}
	// 最低版本号是「把所有人挡在门外」的开关，配错代价很高：
	// 负数当 0（关闭），比最新版还高就夹到最新版，最多退化成普通更新。
	if rel.MinVersionCode < 0 {
		rel.MinVersionCode = 0
	}
	if rel.MinVersionCode > rel.VersionCode {
		slog.Warn("latest.json 的 min_version_code 大于 version_code，已按最新版处理",
			"min_version_code", rel.MinVersionCode, "version_code", rel.VersionCode)
		rel.MinVersionCode = rel.VersionCode
	}
	return &rel, nil
}

// latestApp 返回最新客户端版本信息；没有发布过版本时 404（客户端视为无更新）。
func (s *Server) latestApp(c *gin.Context) {
	rel, err := s.latestRelease()
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "latest.json 解析失败", "dir", s.releaseDir, "err", err)
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": "版本信息格式错误"})
		return
	}
	if rel == nil {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "暂无版本信息"})
		return
	}
	c.JSON(nethttp.StatusOK, rel)
}

// downloadApp 下发 APK。只允许下载 releases 目录下的 .apk，防止路径穿越。
func (s *Server) downloadApp(c *gin.Context) {
	name := c.Param("file")
	// 只接受裸文件名 + .apk 后缀，拒绝 ../ 之类
	if name == "" || name != filepath.Base(name) || !strings.HasSuffix(strings.ToLower(name), ".apk") {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "文件名不合法"})
		return
	}
	path := filepath.Join(s.releaseDir, name)
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && info.IsDir()) {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "安装包不存在"})
		return
	}
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.Header("Content-Type", "application/vnd.android.package-archive")
	c.Header("Content-Disposition", `attachment; filename="`+name+`"`)
	// c.File 走 http.ServeFile，自带 Range 支持，客户端中断后可续传
	c.File(path)
}
