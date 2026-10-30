package http

import (
	"context"
	nethttp "net/http"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
)

// Health 记录进程的生命周期状态，把「活着」和「能接新活」分成两件事。
//
// 发布时要区分这两种语义，否则优雅退出本身会制造误报：
//   - /healthz（liveness）：进程还活着就 200，排空期间也是 200。watchdog 和
//     UptimeRobot 只看这个，不能把「正在收尾」当成「服务挂了」。
//   - /readyz（readiness）：排空期间 503，部署脚本据此判断新版本是否真的能服务。
//
// 反过来如果让 /healthz 在排空期间返 503，一次发布的告警窗口会从几秒变成
// 整个排空时长（最长 130 秒），撞上 watchdog 的概率反而更高。
type Health struct {
	ready    atomic.Bool
	draining atomic.Bool
	inflight atomic.Int64
}

func NewHealth() *Health {
	h := &Health{}
	h.ready.Store(true)
	return h
}

// StartDraining 标记进入排空阶段：不再接新活，已有请求继续跑完。
func (h *Health) StartDraining() { h.draining.Store(true) }

// Ready 表示可以接新请求（未排空且已完成启动）。
func (h *Health) Ready() bool { return h.ready.Load() && !h.draining.Load() }

func (h *Health) Draining() bool { return h.draining.Load() }

// BeginRequest 是排空闸门：返回 false 表示进程正在收尾，不该再接新请求。
// 排空期间保留监听端口，新请求拿到明确的 503，而不是 connection refused。
func (h *Health) BeginRequest() bool {
	if h.draining.Load() {
		return false
	}
	h.inflight.Add(1)
	return true
}

func (h *Health) EndRequest() { h.inflight.Add(-1) }

// Inflight 是当前还没跑完的请求数（含 SSE 长连接）。
func (h *Health) Inflight() int64 { return h.inflight.Load() }

// WaitIdle 等到没有在途请求，或 ctx 超时。
func (h *Health) WaitIdle(ctx context.Context) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		if h.inflight.Load() == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// gate 拦截排空期间的新请求；两个探针不在统计范围内，必须始终可达。
func (h *Health) gate() gin.HandlerFunc {
	return func(c *gin.Context) {
		if p := c.Request.URL.Path; p == "/healthz" || p == "/readyz" {
			c.Next()
			return
		}
		if !h.BeginRequest() {
			c.Header("Retry-After", "5")
			c.AbortWithStatusJSON(nethttp.StatusServiceUnavailable, gin.H{
				"error": "服务正在更新，请稍后再试",
			})
			return
		}
		defer h.EndRequest()
		c.Next()
	}
}

// healthz 只回答「进程还在不在」，排空期间也返回 200。
func (s *Server) healthz(c *gin.Context) {
	c.JSON(nethttp.StatusOK, gin.H{"status": "ok", "service": "piggy-pal"})
}

// readyz 回答「现在能不能接新活」，部署脚本和（将来的）反向代理用它做切流判断。
func (s *Server) readyz(c *gin.Context) {
	reason := ""
	switch {
	case s.health == nil || !s.health.Ready():
		reason = "starting"
		if s.health != nil && s.health.Draining() {
			reason = "draining"
		}
	case !s.storeReady(c.Request.Context()):
		reason = "db"
	}
	if reason != "" {
		c.JSON(nethttp.StatusServiceUnavailable, gin.H{"status": "unavailable", "reason": reason})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"status": "ok"})
}

// storeReady 给健康检查一次很短的数据库探测，避免库被锁死时还把流量放进来。
func (s *Server) storeReady(ctx context.Context) bool {
	probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	return s.store.Ping(probeCtx) == nil
}
