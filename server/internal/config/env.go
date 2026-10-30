package config

import (
	"os"
	"strconv"

	"github.com/joho/godotenv"
)

// Env 保存运行时环境变量与腾讯云凭证。
type Env struct {
	CAMSecretID  string // 腾讯云 CAM（TTS / ASR 用）
	CAMSecretKey string
	Region       string

	LLMToken   string // DeepSeek（OpenAI 兼容接口）
	LLMBaseURL string
	LLMModel   string

	// APIToken 全站共享访问令牌（客户端用 X-API-Token 头携带）。
	// 为空时不校验，仅限本地开发；公网部署务必设置。
	APIToken string

	// AdminToken 运维管理令牌（发指令、看设备列表）。
	// 为空时 /admin 接口整体关闭；不要编译进客户端。
	AdminToken string

	ASREngine string // ASR 引擎类型，默认 16k_zh-PY（中英粤）

	Port    string
	DataDir string

	// ClientLogDir App 上传日志的保存目录（与 server.log 分开）。
	ClientLogDir string
}

// LoadEnv 读取环境变量（本地开发优先读 .env，生产由 systemd EnvironmentFile / docker env_file 注入）。
func LoadEnv() *Env {
	// 失败忽略：生产环境没有 .env 文件，凭证由外部注入。
	_ = godotenv.Load()

	return &Env{
		CAMSecretID:  getenv("TENCENTCLOUD_SECRET_ID", ""),
		CAMSecretKey: getenv("TENCENTCLOUD_SECRET_KEY", ""),
		Region:       getenv("TENCENTCLOUD_REGION", "ap-guangzhou"),

		LLMToken:   getenv("LLM_TOKEN", ""),
		LLMBaseURL: getenv("LLM_BASE_URL", "https://api.deepseek.com"),
		LLMModel:   getenv("LLM_MODEL", "deepseek-chat"),

		APIToken:   getenv("API_TOKEN", ""),
		AdminToken: getenv("ADMIN_TOKEN", ""),

		ASREngine: getenv("ASR_ENGINE", "16k_zh-PY"),

		Port:    getenv("PORT", "18080"),
		DataDir: getenv("DATA_DIR", "./data"),

		ClientLogDir: getenv("CLIENT_LOG_DIR", "/var/log/piggy-pal/client"),
	}
}

// HasCAM 是否已配置腾讯云 CAM 密钥（TTS / ASR 可用）。
func (e *Env) HasCAM() bool { return e.CAMSecretID != "" && e.CAMSecretKey != "" }

// HasLLM 是否已配置 LLM Token（LLM 可用）。
func (e *Env) HasLLM() bool { return e.LLMToken != "" }

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// getenvInt 读取整型环境变量，解析失败返回默认值。
func getenvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
