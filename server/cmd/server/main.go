package main

import (
	"context"
	"errors"
	"log/slog"
	nethttp "net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"piggy-pal/server/internal/config"
	"piggy-pal/server/internal/dict"
	serverhttp "piggy-pal/server/internal/http"
	"piggy-pal/server/internal/service"
	"piggy-pal/server/internal/store"
)

// drainTimeout 是优雅退出的排空上限：单个 SSE 对话最长约 120 秒，留 10 秒余量。
// systemd 的 TimeoutStopSec（见 deploy/piggy-pal.service）必须比它长，否则会被 SIGKILL 截断。
const drainTimeout = 130 * time.Second

func main() {
	// 结构化日志：dev 用文本格式 + 源码位置，方便定位问题。
	// ContextHandler 会给请求内的日志自动补上 client_id / child_id，
	// 这样服务端日志能和具体是哪台设备对上（客户端每个请求都带 X-Client-Id）。
	slog.SetDefault(slog.New(serverhttp.NewContextHandler(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level:     slog.LevelDebug,
		AddSource: true,
	}))))

	env := config.LoadEnv()

	roles, err := config.LoadRoles("config/roles.yaml")
	if err != nil {
		slog.Error("加载 roles.yaml 失败", "err", err)
		os.Exit(1)
	}
	slog.Info("已加载角色", "count", len(roles.Roles))

	// prompts / guard 加载失败仅告警，不阻断启动（mock 模式下可缺省）。
	var prompts *config.PromptsConfig
	if prompts, err = config.LoadPrompts("config/prompts.yaml"); err != nil {
		slog.Warn("加载 prompts.yaml 失败（将使用角色人设兜底）", "err", err)
	}
	var guardCfg *config.GuardConfig
	if guardCfg, err = config.LoadGuard("config/guard.yaml"); err != nil {
		slog.Warn("加载 guard.yaml 失败（护栏关闭）", "err", err)
	}

	st, err := store.Open(env.DataDir)
	if err != nil {
		slog.Error("打开 SQLite 失败", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	llm := service.NewLLMService(env.LLMBaseURL, env.LLMToken, env.LLMModel)
	tts := service.NewTTSService(env.CAMSecretID, env.CAMSecretKey, env.Region, filepath.Join(env.DataDir, "tts-cache"))
	asr := service.NewASRService(env.CAMSecretID, env.CAMSecretKey, env.Region, env.ASREngine)
	guard := service.NewGuardService(guardCfg)
	chat := service.NewChatService(st, llm, tts, asr, guard, roles, prompts)

	// 内置词典：14k 常用词 + 169 个童词 + 1000 词真人发音，随二进制打包。
	if d, err := dict.Load(); err != nil {
		slog.Warn("内置词典加载失败，点词查词不可用", "err", err)
	} else {
		chat.SetDictionary(d)
		kid, base, audio := d.Stats()
		slog.Info("已加载内置词典", "kid", kid, "base", base, "human_audio", audio)
	}

	// 角色首页语音是固定文案：启动时后台预热，命中磁盘缓存就是 0 成本读文件，
	// 之后用户请求不再触发 TTS 合成。
	go chat.WarmupGreetings(context.Background())

	// 客户端上传日志目录：优先 /var/log/piggy-pal/client（与 server.log 分开）。
	// 权限不足时回退到数据目录，保证上传功能不因目录问题整体失败。
	clientLogDir := env.ClientLogDir
	if err := os.MkdirAll(clientLogDir, 0o755); err != nil {
		fallback := filepath.Join(env.DataDir, "client-logs")
		slog.Warn("客户端日志目录不可用，回退到数据目录",
			"dir", clientLogDir, "fallback", fallback, "err", err)
		clientLogDir = fallback
	}

	health := serverhttp.NewHealth()
	r := serverhttp.NewRouter(st, roles, chat, env.APIToken, clientLogDir,
		filepath.Join(env.DataDir, "releases"), env.AdminToken, health)

	slog.Info("PiggyPal 启动", "port", env.Port,
		"llm", llm.Enabled(), "tts", tts.Enabled(), "asr", asr.Enabled(),
		"auth", env.APIToken != "", "client_log_dir", clientLogDir,
		"drain_timeout", drainTimeout.String())

	// 自己持有 http.Server 而不是 r.Run()：r.Run() 收到 SIGTERM 会被 systemd 直接杀掉，
	// 在途的 LLM / TTS / SSE 全部腰斩。这里改成「先排空再退出」。
	srv := &nethttp.Server{
		Addr:              ":" + env.Port,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
	}

	// 第二根信号走默认行为（立即退出），排空卡住时还能强制停。
	signalCtx, stopSignals := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stopSignals()

	serveErr := make(chan error, 1)
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, nethttp.ErrServerClosed) {
			serveErr <- err
		}
	}()

	select {
	case err := <-serveErr:
		slog.Error("服务启动失败", "err", err)
		os.Exit(1)
	case <-signalCtx.Done():
	}

	stopSignals()
	// healthz 保持 200（进程还活着），readyz 立刻 503（不再接新活），
	// 普通请求由排空闸门直接返回 503，不留给客户端一个 connection refused。
	health.StartDraining()
	slog.Info("收到退出信号，开始排空在途请求", "timeout", drainTimeout.String())

	drainCtx, cancelDrain := context.WithTimeout(context.Background(), drainTimeout)
	defer cancelDrain()
	// 先等在途请求跑完，再关监听：这样排空期间 /healthz 仍然可达，
	// watchdog / UptimeRobot 不会把「正在收尾」判成「挂了」。
	if err := health.WaitIdle(drainCtx); err != nil {
		slog.Warn("排空超时，仍有请求未完成", "inflight", health.Inflight())
	}
	if err := srv.Shutdown(drainCtx); err != nil {
		slog.Warn("关闭监听失败，强制关闭", "err", err)
		_ = srv.Close()
	}
	slog.Info("服务已停止")
}
