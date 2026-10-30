package http

import (
	"context"
	"log/slog"
	"time"

	"github.com/gin-gonic/gin"
)

// 请求级日志上下文：把 client_id / child_id 挂到 context 上，
// 这样 handler 内部用 slog.XxxContext 打的日志也能自动带上，不用每处手动传。
type logContextKey struct{}

type requestLogInfo struct {
	clientID string
	childID  string
}

// requestContext 从请求头 X-Client-Id 取设备标识（客户端每个请求都会带），
// 路径里有 child_id 的接口顺手记下来，方便把日志对上「哪台设备 + 哪个宝宝」。
func requestContext() gin.HandlerFunc {
	return func(c *gin.Context) {
		info := requestLogInfo{childID: c.Param("child_id")}

		// 只接受和心跳相同的安全字符集，避免日志注入 / 目录穿越
		if id := c.GetHeader("X-Client-Id"); clientIDRe.MatchString(id) {
			info.clientID = id
			c.Set("client_id", id)
		}

		c.Request = c.Request.WithContext(
			context.WithValue(c.Request.Context(), logContextKey{}, info),
		)
		c.Next()
	}
}

// accessLog 替代 gin.Default() 自带的 Logger：字段和它基本一致，
// 额外带上 client_id / child_id，排查时一眼能看出这条请求是哪台手机发的。
func accessLog() gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		path := c.Request.URL.Path
		if raw := c.Request.URL.RawQuery; raw != "" {
			path += "?" + raw
		}

		c.Next()

		attrs := []any{
			"method", c.Request.Method,
			"path", path,
			"status", c.Writer.Status(),
			"latency", time.Since(start).Round(time.Microsecond),
			"ip", c.ClientIP(),
			"size", c.Writer.Size(),
		}
		if info, ok := c.Request.Context().Value(logContextKey{}).(requestLogInfo); ok {
			if info.clientID != "" {
				attrs = append(attrs, "client_id", info.clientID)
			}
			if info.childID != "" {
				attrs = append(attrs, "child_id", info.childID)
			}
		}
		if errs := c.Errors.ByType(gin.ErrorTypePrivate).String(); errs != "" {
			attrs = append(attrs, "errors", errs)
		}

		// 不用 Context 版本：client_id / child_id 已经手动放进 attrs，
		// 再走 ContextHandler 会重复输出一遍。
		// 5xx 用 Error 级别，方便直接 grep level=ERROR
		if c.Writer.Status() >= 500 {
			slog.Error("http", attrs...)
		} else {
			slog.Info("http", attrs...)
		}
	}
}

// contextHandler 给所有 slog 日志补上请求上下文里的 client_id / child_id。
type contextHandler struct {
	slog.Handler
}

// NewContextHandler 包装默认日志 handler：handler 里用 slog.XxxContext 打的日志
// 会自动带上 client_id / child_id（没有上下文时和原来完全一样）。
func NewContextHandler(inner slog.Handler) slog.Handler {
	return &contextHandler{Handler: inner}
}

func (h *contextHandler) Handle(ctx context.Context, r slog.Record) error {
	if info, ok := ctx.Value(logContextKey{}).(requestLogInfo); ok {
		if info.clientID != "" {
			r.AddAttrs(slog.String("client_id", info.clientID))
		}
		if info.childID != "" {
			r.AddAttrs(slog.String("child_id", info.childID))
		}
	}
	return h.Handler.Handle(ctx, r)
}

func (h *contextHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &contextHandler{Handler: h.Handler.WithAttrs(attrs)}
}

func (h *contextHandler) WithGroup(name string) slog.Handler {
	return &contextHandler{Handler: h.Handler.WithGroup(name)}
}
