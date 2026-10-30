package http

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	nethttp "net/http"
	"strconv"
	"strings"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/service"
	"piggy-pal/server/internal/store"

	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

const defaultFamilyID = "default"

// Server 持有各依赖，作为 handler 的载体。
type Server struct {
	store        *store.Store
	roles        *config.RolesConfig
	chatSvc      *service.ChatService
	clientLogDir string
	releaseDir   string
	health       *Health
}

// NewRouter 构建 Gin 路由。
// apiToken 非空时，除 /healthz 和 /readyz 外的所有接口都要求请求头 X-API-Token（也兼容 Authorization: Bearer）。
// clientLogDir 是客户端上传日志的落盘目录（与 server.log 分开）。
// releaseDir 存放 APK 与 latest.json，供客户端自动更新。
// adminToken 为空时管理接口整体关闭（返回 404）。
func NewRouter(st *store.Store, roles *config.RolesConfig, chat *service.ChatService, apiToken, clientLogDir, releaseDir, adminToken string, health *Health) *gin.Engine {
	s := &Server{store: st, roles: roles, chatSvc: chat, clientLogDir: clientLogDir, releaseDir: releaseDir, health: health}
	// 自己拼中间件而不用 gin.Default()：访问日志要带 client_id / child_id。
	// 顺序：Recovery → 排空闸门 → 请求上下文 → 访问日志 → 鉴权（401 也会被记下来）。
	middlewares := []gin.HandlerFunc{gin.Recovery()}
	if health != nil {
		middlewares = append(middlewares, health.gate())
	}
	middlewares = append(middlewares, requestContext(), accessLog(), requireToken(apiToken))
	r := gin.New()
	r.Use(middlewares...)

	r.GET("/healthz", s.healthz)
	// 就绪探针：排空 / 数据库不可用时 503，部署脚本用它判断新版本是否真的能服务
	r.GET("/readyz", s.readyz)

	// 角色列表（精简，不暴露 persona / voice_id）
	r.GET("/roles", s.listRoles)
	// 角色语音（首页自动播放：自我介绍 + 英文口号）
	r.GET("/roles/:role_id/greet", s.roleGreeting)
	// 倒计时语音提醒（剩 2 分钟 / 30 秒）：文案固定 + TTS 磁盘缓存
	r.GET("/roles/:role_id/time-warning", s.timeWarning)

	// 客户端运行日志上传（与服务端日志分目录保存，按 client_id 隔离）
	r.POST("/client-logs", s.uploadClientLog)

	// 客户端心跳：上报本次运行时长 + 领取服务端指令
	r.POST("/client/heartbeat", s.heartbeat)
	r.POST("/client/commands/:id/ack", s.ackCommand)

	// 运维管理接口：设备列表、下发指令（额外要求 X-Admin-Token）
	admin := r.Group("/admin", requireAdminToken(adminToken))
	{
		admin.GET("/clients", s.listClients)
		admin.POST("/clients/:client_id/commands", s.createCommand)
		admin.GET("/clients/:client_id/commands", s.listCommands)
	}

	// 客户端自动更新：版本信息 + APK 下载（APK 支持 Range，断点续传）
	r.GET("/app/latest", s.latestApp)
	r.GET("/app/download/:file", s.downloadApp)

	// 宝宝端
	child := r.Group("/child")
	{
		child.GET("", s.listChildren)
		child.POST("", s.upsertChild)
		child.GET("/:child_id", s.getChild)
		child.POST("/:child_id/chat", s.handleChat)
		// 流式对话：ASR 完成先推文本，LLM 完成推回复，TTS 按句推音频
		child.POST("/:child_id/chat/stream", s.handleChatStream)
		child.GET("/:child_id/stats", s.getChildStats)
		// 本周学习计划：周一自动生成，返回 7 天目标词 + 每天听到/说出进度
		child.GET("/:child_id/learning-plan", s.learningPlan)
		// 贴纸墙：按累计星星解锁，不消费星星
		child.GET("/:child_id/stickers", s.stickerBoard)
		// 睡前故事：每天一段，?slow=1 用更慢语速
		child.GET("/:child_id/bedtime-story/:role_id", s.bedtimeStory)
		child.GET("/:child_id/messages", s.listMessages)
		// 点词查词典：msg_id 用来取点击所在原句做语境例句
		child.GET("/:child_id/dict/:word", s.lookupWord)
		child.GET("/:child_id/messages/:message_id/audio", s.messageAudio)
		child.GET("/:child_id/daily-greeting/:role_id", s.dailyGreeting)
		child.POST("/:child_id/session", s.recordSession)
		child.POST("/:child_id/session/sync", s.syncSession)
		child.POST("/:child_id/bye", s.goodbye)
	}

	// 家长端
	parent := r.Group("/parent")
	{
		parent.POST("/verify", s.verifyPIN)
		parent.POST("/pin", s.setPIN)
	}

	return r
}

// requireToken 校验全站共享令牌。token 为空时关闭校验（仅限本地开发）。
// requireAdminToken 校验运维管理令牌。未配置时整个 /admin 关闭（404，不暴露存在性）。
func requireAdminToken(token string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if token == "" {
			c.AbortWithStatusJSON(nethttp.StatusNotFound, gin.H{"error": "未开启管理接口"})
			return
		}
		got := c.GetHeader("X-Admin-Token")
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			c.AbortWithStatusJSON(nethttp.StatusUnauthorized, gin.H{"error": "管理令牌不正确"})
			return
		}
		c.Next()
	}
}

func requireToken(token string) gin.HandlerFunc {
	return func(c *gin.Context) {
		if token == "" || c.Request.URL.Path == "/healthz" || c.Request.URL.Path == "/readyz" {
			c.Next()
			return
		}
		got := c.GetHeader("X-API-Token")
		if got == "" {
			if h := c.GetHeader("Authorization"); strings.HasPrefix(h, "Bearer ") {
				got = strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
			}
		}
		// 定长比较，避免按字符泄露 token 长度/内容
		if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
			c.AbortWithStatusJSON(nethttp.StatusUnauthorized, gin.H{"error": "未授权：缺少或错误的 X-API-Token"})
			return
		}
		c.Next()
	}
}

type roleVO struct {
	RoleID      string `json:"role_id"`
	Name        string `json:"name"`
	En          string `json:"en"`
	Catchphrase string `json:"catchphrase"`
	SayEn       string `json:"say_en"`
	Hello       string `json:"hello"`
}

func (s *Server) listRoles(c *gin.Context) {
	out := make([]roleVO, 0, len(s.roles.Roles))
	for _, r := range s.roles.Roles {
		out = append(out, roleVO{
			RoleID:      r.RoleID,
			Name:        r.Name,
			En:          r.En,
			Catchphrase: r.Catchphrase,
			SayEn:       r.SayEn,
			Hello:       r.Hello,
		})
	}
	c.JSON(nethttp.StatusOK, gin.H{"roles": out})
}

// listMessages 返回某宝宝与某角色的历史对话（正序），供再次进入对话页时回显。
// before_id > 0 时取更早的一页，客户端上滑加载更多；has_more 表示还有没有更早的。
func (s *Server) listMessages(c *gin.Context) {
	roleID := strings.TrimSpace(c.Query("role_id"))
	if roleID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 role_id"})
		return
	}
	limit := 50
	if v := strings.TrimSpace(c.Query("limit")); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			c.JSON(nethttp.StatusBadRequest, gin.H{"error": "limit 不合法"})
			return
		}
		if n < 1 {
			n = 1
		}
		if n > 100 {
			n = 100
		}
		limit = n
	}
	var beforeID int64
	if v := strings.TrimSpace(c.Query("before_id")); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			c.JSON(nethttp.StatusBadRequest, gin.H{"error": "before_id 不合法"})
			return
		}
		beforeID = n
	}
	msgs, hasMore, err := s.store.MessagesPage(c.Param("child_id"), roleID, beforeID, limit)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if msgs == nil {
		msgs = []model.ChatMessage{}
	}
	c.JSON(nethttp.StatusOK, gin.H{"messages": msgs, "has_more": hasMore})
}

// messageAudio 重播历史消息：按该条 AI 消息的角色音色合成语音。
// 历史接口不返回音频（避免响应过大），客户端点喇叭时再按消息 ID 取。
func (s *Server) messageAudio(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	id, err := strconv.ParseInt(c.Param("message_id"), 10, 64)
	if err != nil || id <= 0 {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "message_id 不合法"})
		return
	}
	msg, err := s.store.GetMessage(c.Param("child_id"), id)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if msg == nil {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "消息不存在"})
		return
	}
	if msg.Speaker != "ai" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "只有 AI 消息可以重播"})
		return
	}
	// slow=1 用 0.75 倍语速（缓存键含语速，慢速版单独缓存，不会覆盖正常版）
	var audio string
	if c.Query("slow") == "1" {
		audio, err = s.chatSvc.SpeakSlow(c.Request.Context(), msg.RoleID, msg.Content)
	} else {
		audio, err = s.chatSvc.Speak(c.Request.Context(), msg.RoleID, msg.Content)
	}
	if err != nil {
		// TTS 未配置 / 合成失败：客户端静默跳过语音，不影响历史展示
		slog.WarnContext(c.Request.Context(), "历史消息语音不可用",
			"child_id", msg.ChildID, "message_id", msg.ID, "err", err)
		c.JSON(nethttp.StatusServiceUnavailable, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"audio_b64": audio, "audio_format": "mp3"})
}

// dailyGreeting 返回今天的开场话题：当天首次调用时由大模型生成并落库，之后复用。
func (s *Server) dailyGreeting(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	resp, err := s.chatSvc.DailyGreeting(c.Request.Context(), c.Param("child_id"), c.Param("role_id"))
	switch {
	case errors.Is(err, service.ErrRoleNotFound):
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "角色不存在"})
		return
	case err != nil:
		slog.ErrorContext(c.Request.Context(), "生成今日话题失败",
			"child_id", c.Param("child_id"), "role_id", c.Param("role_id"), "err", err)
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

// roleGreeting 返回角色首页语音（自我介绍 + 英文口号）。客户端的首次进入 / 切换角色时播放。
func (s *Server) roleGreeting(c *gin.Context) {
	roleID := c.Param("role_id")
	resp, err := s.chatSvc.RoleGreeting(c.Request.Context(), roleID)
	switch {
	case errors.Is(err, service.ErrRoleNotFound):
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "角色不存在"})
		return
	case err != nil:
		// TTS 未配置 / 合成失败：客户端静默跳过语音，不影响页面展示
		slog.WarnContext(c.Request.Context(), "角色语音不可用", "role_id", roleID, "err", err)
		c.JSON(nethttp.StatusServiceUnavailable, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

// timeWarning 返回倒计时语音提醒。kind 只接受 2min / 30s，
// 文案和语速都由服务端决定，客户端不能传任意文本进来（避免被当成免费 TTS 用）。
func (s *Server) timeWarning(c *gin.Context) {
	roleID := c.Param("role_id")
	kind := c.DefaultQuery("kind", "2min")
	resp, err := s.chatSvc.TimeWarning(c.Request.Context(), roleID, kind)
	switch {
	case errors.Is(err, service.ErrRoleNotFound):
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "角色不存在"})
		return
	case errors.Is(err, service.ErrBadWarningKind):
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "kind 只支持 2min / 30s"})
		return
	case err != nil:
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

func (s *Server) listChildren(c *gin.Context) {
	children, err := s.store.ListChildren()
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"children": children})
}

func (s *Server) getChild(c *gin.Context) {
	child, err := s.store.GetChild(c.Param("child_id"))
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if child == nil {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "宝宝不存在"})
		return
	}
	c.JSON(nethttp.StatusOK, child)
}

func (s *Server) upsertChild(c *gin.Context) {
	var req model.Child
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	req.EnName = strings.TrimSpace(req.EnName)
	if req.ChildID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 child_id"})
		return
	}
	if req.Name == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少中文名"})
		return
	}
	// 英文名必填：LLM 会用英文名称呼宝宝，也方便以后做英语启蒙
	if req.EnName == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少英文名"})
		return
	}
	if req.FamilyID == "" {
		req.FamilyID = defaultFamilyID
	}
	if err := s.store.UpsertChild(&req); err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, req)
}

// handleChat 处理一次对话（text 或 audio_b64 二选一）。
func (s *Server) handleChat(c *gin.Context) {
	childID := c.Param("child_id")
	// 语音以 base64 传入：限制 12MB，约 4 分钟 16k 单声道 WAV，防止异常请求打满内存
	c.Request.Body = nethttp.MaxBytesReader(c.Writer, c.Request.Body, 12<<20)
	var req model.ChatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		var tooLarge *nethttp.MaxBytesError
		if errors.As(err, &tooLarge) {
			c.JSON(nethttp.StatusRequestEntityTooLarge, gin.H{"error": "语音太长啦"})
			return
		}
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.RoleID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 role_id"})
		return
	}
	resp, err := s.chatSvc.Handle(c.Request.Context(), childID, &req)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "chat 处理失败",
			"child_id", childID, "role_id", req.RoleID, "err", err)
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

// handleChatStream 流式对话（SSE）：分阶段推送 asr / reply / audio。
// 客户端据此在 ASR 完成时就显示宝宝说的话，不用等 LLM + TTS 全部跑完。
func (s *Server) handleChatStream(c *gin.Context) {
	childID := c.Param("child_id")
	// 与普通对话一致：语音 base64 上限 12MB
	c.Request.Body = nethttp.MaxBytesReader(c.Writer, c.Request.Body, 12<<20)
	var req model.ChatRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		var tooLarge *nethttp.MaxBytesError
		if errors.As(err, &tooLarge) {
			c.JSON(nethttp.StatusRequestEntityTooLarge, gin.H{"error": "语音太长啦"})
			return
		}
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.RoleID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 role_id"})
		return
	}
	if strings.TrimSpace(req.Text) == "" && strings.TrimSpace(req.AudioB64) == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "输入为空"})
		return
	}
	// 角色不存在等「开始流之前就能判断」的错误，仍然用正常 HTTP 状态码返回，
	// 不要先写 200 再塞 error 事件，客户端更好处理。
	if !s.chatSvc.RoleExists(req.RoleID) {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "角色不存在"})
		return
	}

	c.Writer.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	c.Writer.Header().Set("Cache-Control", "no-cache")
	c.Writer.Header().Set("Connection", "keep-alive")
	// 让 Caddy / Nginx 不要缓冲 SSE，保证事件一产生就到达客户端
	c.Writer.Header().Set("X-Accel-Buffering", "no")
	c.Status(nethttp.StatusOK)
	c.Writer.WriteHeaderNow()

	flusher, _ := c.Writer.(nethttp.Flusher)
	writeEvent := func(event string, payload any) error {
		data, err := json.Marshal(payload)
		if err != nil {
			return err
		}
		if _, err := fmt.Fprintf(c.Writer, "event: %s\ndata: %s\n\n", event, data); err != nil {
			return err
		}
		if flusher != nil {
			flusher.Flush()
		}
		return nil
	}

	err := s.chatSvc.HandleStream(c.Request.Context(), childID, &req, func(ev service.StreamEvent) error {
		return writeEvent(ev.Type, ev)
	})
	if err != nil {
		slog.WarnContext(c.Request.Context(), "stream chat 失败",
			"child_id", childID, "role_id", req.RoleID, "err", err)
		// 已经写了 200 头，只能通过 error 事件告知客户端
		_ = writeEvent("error", gin.H{"error": err.Error()})
	}
}

// childExists 统一校验宝宝是否存在，避免给不存在的宝宝写脏数据。
func (s *Server) childExists(c *gin.Context) bool {
	child, err := s.store.GetChild(c.Param("child_id"))
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return false
	}
	if child == nil {
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "宝宝不存在"})
		return false
	}
	return true
}

// getChildStats 返回星星页 / 家长报告需要的统计数据。
func (s *Server) getChildStats(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	childID := c.Param("child_id")
	stats, err := s.store.GetChildStats(childID)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	// 学习计划只统计计划内的词：近 7 天里已经生成过计划的日期才有数。
	if len(stats.Week) > 0 {
		start, end := stats.Week[0].Date, stats.Week[len(stats.Week)-1].Date
		if progress, err := s.chatSvc.PlanProgress(c.Request.Context(), childID, start, end); err != nil {
			slog.WarnContext(c.Request.Context(), "读取学习计划进度失败", "child_id", childID, "err", err)
		} else {
			for i := range stats.Week {
				p := progress[stats.Week[i].Date]
				if p == nil {
					continue
				}
				stats.Week[i].PlanWords = p.PlanWords
				stats.Week[i].WordsHeard = p.Heard
				stats.Week[i].WordsSaid = p.Said
			}
			if p := progress[stats.Today.Date]; p != nil {
				stats.Today.PlanWords = p.PlanWords
				stats.Today.WordsHeard = p.Heard
				stats.Today.WordsSaid = p.Said
			}
		}
	}
	// 间隔重复：今天到期该复习的词 / 已掌握的词
	if toReview, mastered, err := s.store.WordLearningStats(childID, stats.Today.Date); err != nil {
		slog.WarnContext(c.Request.Context(), "读取单词掌握度失败", "child_id", childID, "err", err)
	} else {
		stats.WordsToReview = toReview
		stats.WordsMastered = mastered
	}
	c.JSON(nethttp.StatusOK, stats)
}

// stickerBoard 返回贴纸墙：累计星星 + 每张贴纸的解锁状态。
func (s *Server) stickerBoard(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	board, err := s.chatSvc.StickerBoard(c.Request.Context(), c.Param("child_id"))
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, board)
}

// bedtimeStory 返回今天的睡前故事（当天生成一次）。slow=1 时用 0.75 倍语速。
func (s *Server) bedtimeStory(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	resp, err := s.chatSvc.BedtimeStory(c.Request.Context(), c.Param("child_id"),
		c.Param("role_id"), c.Query("slow") == "1")
	switch {
	case errors.Is(err, service.ErrRoleNotFound):
		c.JSON(nethttp.StatusNotFound, gin.H{"error": "角色不存在"})
		return
	case err != nil:
		slog.ErrorContext(c.Request.Context(), "生成睡前故事失败",
			"child_id", c.Param("child_id"), "role_id", c.Param("role_id"), "err", err)
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

// learningPlan 返回本周学习计划与进度。第一次调用会自动生成（LLM 失败走兜底词库）。
func (s *Server) learningPlan(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	plan, err := s.chatSvc.LearningPlan(c.Request.Context(), c.Param("child_id"))
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, plan)
}

// lookupWord 查询单词：音标、释义、例句、真人发音（正常 / 慢读）。
func (s *Server) lookupWord(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	msgID, _ := strconv.ParseInt(c.Query("msg_id"), 10, 64)
	entry, err := s.chatSvc.LookupWord(c.Request.Context(), c.Param("child_id"),
		c.Query("role_id"), c.Param("word"), msgID)
	if err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, entry)
}

// recordSession 客户端结束陪伴时上报时长 / 打开次数。
func (s *Server) recordSession(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	var req model.SessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	// 防御异常上报：单次时长最多 1 小时，打开次数最多 10
	if req.DurationSec < 0 {
		req.DurationSec = 0
	}
	if req.DurationSec > 3600 {
		req.DurationSec = 3600
	}
	if req.OpenCount < 0 {
		req.OpenCount = 0
	}
	if req.OpenCount > 10 {
		req.OpenCount = 10
	}
	if err := s.store.RecordActivity(c.Param("child_id"), 0, 0, req.DurationSec, req.OpenCount); err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": true})
}

// syncSession 客户端防抖同步本次会话星星（绝对值快照，只增不减）。
func (s *Server) syncSession(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	var req model.SessionSyncRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.SessionID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 session_id"})
		return
	}
	if req.Stars < 0 {
		req.Stars = 0
	}
	// 防御异常值：单次会话星星不会超过 999
	if req.Stars > 999 {
		req.Stars = 999
	}
	stars, err := s.store.SyncSession(c.Param("child_id"), req.SessionID, req.Stars)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": true, "session_stars": stars})
}

// goodbye 生成结束页的道别 + 星星结算 + 预告明日。
func (s *Server) goodbye(c *gin.Context) {
	if !s.childExists(c) {
		return
	}
	var req model.GoodbyeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.RoleID == "" {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "缺少 role_id"})
		return
	}
	if req.Stars < 0 {
		req.Stars = 0
	}
	// 会话星星以服务端记录为准；客户端快照只用于兜底。
	if req.SessionID != "" {
		if stars, err := s.store.GetSessionStars(c.Param("child_id"), req.SessionID); err == nil && stars > req.Stars {
			req.Stars = stars
		}
	}
	resp, err := s.chatSvc.Goodbye(c.Request.Context(), req.RoleID, req.Stars)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "生成结束页失败",
			"role_id", req.RoleID, "err", err)
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, resp)
}

func (s *Server) verifyPIN(c *gin.Context) {
	var req struct {
		FamilyID string `json:"family_id"`
		PIN      string `json:"pin"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.FamilyID == "" {
		req.FamilyID = defaultFamilyID
	}
	hash, err := s.store.GetPIN(req.FamilyID)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if hash == "" {
		c.JSON(nethttp.StatusOK, gin.H{"ok": false, "reason": "未设置 PIN"})
		return
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(req.PIN)) == nil {
		c.JSON(nethttp.StatusOK, gin.H{"ok": true})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": false, "reason": "PIN 错误"})
}

func (s *Server) setPIN(c *gin.Context) {
	var req struct {
		FamilyID string `json:"family_id"`
		PIN      string `json:"pin"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "参数错误"})
		return
	}
	if req.FamilyID == "" {
		req.FamilyID = defaultFamilyID
	}
	if len(req.PIN) < 4 {
		c.JSON(nethttp.StatusBadRequest, gin.H{"error": "PIN 至少 4 位"})
		return
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(req.PIN), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if err := s.store.SetPIN(req.FamilyID, string(hash)); err != nil {
		c.JSON(nethttp.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(nethttp.StatusOK, gin.H{"ok": true})
}
