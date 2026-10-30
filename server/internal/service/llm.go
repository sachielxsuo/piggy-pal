package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// LLMMessage 一条对话消息（OpenAI 兼容格式）。
type LLMMessage struct {
	Role    string `json:"role"` // system / user / assistant
	Content string `json:"content"`
}

// LLMService 封装大模型调用（OpenAI 兼容接口，Bearer token），默认接 DeepSeek。
type LLMService struct {
	baseURL string
	token   string
	model   string
	client  *http.Client
}

type llmRequest struct {
	Model    string       `json:"model"`
	Messages []LLMMessage `json:"messages"`
	Stream   bool         `json:"stream"`
}

type llmResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// NewLLMService 构造 LLM 客户端。
func NewLLMService(baseURL, token, model string) *LLMService {
	return &LLMService{
		baseURL: baseURL,
		token:   token,
		model:   model,
		client:  &http.Client{Timeout: 20 * time.Second},
	}
}

// Enabled 是否已配置 token。
func (s *LLMService) Enabled() bool { return s.token != "" }

// Chat 调用 LLM 生成回复。systemPrompt 拼在最前，history 为历史对话，userText 为当前输入。
func (s *LLMService) Chat(ctx context.Context, systemPrompt string, history []LLMMessage, userText string) (string, error) {
	if !s.Enabled() {
		return "", fmt.Errorf("llm token 未配置")
	}

	msgs := make([]LLMMessage, 0, len(history)+2)
	if systemPrompt != "" {
		msgs = append(msgs, LLMMessage{Role: "system", Content: systemPrompt})
	}
	msgs = append(msgs, history...)
	msgs = append(msgs, LLMMessage{Role: "user", Content: userText})

	body, err := json.Marshal(llmRequest{Model: s.model, Messages: msgs, Stream: false})
	if err != nil {
		return "", err
	}

	url := s.baseURL + "/chat/completions"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.token)

	start := time.Now()
	slog.InfoContext(ctx, "LLM 请求开始", "model", s.model, "messages", len(msgs))

	resp, err := s.client.Do(req)
	if err != nil {
		slog.ErrorContext(ctx, "LLM 网络请求失败", "err", err, "cost_ms", time.Since(start).Milliseconds())
		return "", err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		slog.ErrorContext(ctx, "LLM 非 200", "status", resp.StatusCode, "body", string(raw),
			"cost_ms", time.Since(start).Milliseconds())
		return "", fmt.Errorf("LLM 返回 %d: %s", resp.StatusCode, string(raw))
	}

	var parsed llmResponse
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return "", err
	}
	if parsed.Error != nil {
		return "", fmt.Errorf("LLM 错误: %s", parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return "", fmt.Errorf("LLM 无返回内容")
	}
	content := parsed.Choices[0].Message.Content
	slog.InfoContext(ctx, "LLM 请求完成", "model", s.model, "reply_len", len(content),
		"cost_ms", time.Since(start).Milliseconds())
	return content, nil
}
