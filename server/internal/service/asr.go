package service

import (
	"encoding/base64"
	"fmt"
	"log/slog"
	"strings"
	"time"

	asr "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/asr/v20190614"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/profile"
)

// ASRService 封装腾讯云一句话识别（适合「按住说话→松开识别」的整句场景）。
type ASRService struct {
	secretID  string
	secretKey string
	region    string
	engine    string // 如 16k_zh-PY（中英粤）
}

// NewASRService 构造 ASR 服务。
func NewASRService(secretID, secretKey, region, engine string) *ASRService {
	return &ASRService{secretID: secretID, secretKey: secretKey, region: region, engine: engine}
}

// Enabled 是否已配置 CAM 密钥。
func (s *ASRService) Enabled() bool { return s.secretID != "" && s.secretKey != "" }

// Recognize 识别 base64 音频，返回文本。
func (s *ASRService) Recognize(audioB64, voiceFormat string) (string, error) {
	if !s.Enabled() {
		return "", fmt.Errorf("CAM 密钥未配置")
	}
	if voiceFormat == "" {
		voiceFormat = "wav"
	}

	raw, err := base64.StdEncoding.DecodeString(audioB64)
	if err != nil {
		return "", fmt.Errorf("音频 base64 解码失败: %w", err)
	}

	start := time.Now()
	// 16k 单声道 16bit WAV 每秒 32KB，据此估算时长，方便判断离 60 秒上限还有多远。
	// 非 wav 时说不太准，只当量级参考。
	estSec := 0
	if voiceFormat == "wav" {
		estSec = len(raw) / 32000
	}
	slog.Info("ASR 请求开始", "engine", s.engine, "region", s.region,
		"format", voiceFormat, "audio_bytes", len(raw), "audio_sec_est", estSec)

	credential := common.NewCredential(s.secretID, s.secretKey)
	cpf := profile.NewClientProfile()
	client, err := asr.NewClient(credential, s.region, cpf)
	if err != nil {
		return "", err
	}

	request := asr.NewSentenceRecognitionRequest()
	request.EngSerViceType = common.StringPtr(s.engine)
	request.SourceType = common.Uint64Ptr(1) // 1 = 音频数据
	request.VoiceFormat = common.StringPtr(voiceFormat)
	request.Data = common.StringPtr(audioB64)
	request.DataLen = common.Int64Ptr(int64(len(raw)))

	resp, err := client.SentenceRecognition(request)
	if err != nil {
		slog.Error("ASR 调用失败", "err", err, "cost_ms", time.Since(start).Milliseconds())
		return "", err
	}
	if resp.Response == nil || resp.Response.Result == nil {
		slog.Warn("ASR 返回空结果", "cost_ms", time.Since(start).Milliseconds())
		return "", fmt.Errorf("ASR 返回空结果")
	}
	result := strings.TrimSpace(*resp.Response.Result)
	// AudioDuration 是腾讯云回的真实时长（毫秒），比按字节估算准；
	// 配合 60 秒上限看趋势，判断要不要放开客户端的 30 秒录音上限。
	var audioMs int64
	if resp.Response.AudioDuration != nil {
		audioMs = *resp.Response.AudioDuration
	}
	slog.Info("ASR 请求完成", "result_len", len(result), "result", result,
		"audio_ms", audioMs, "cost_ms", time.Since(start).Milliseconds())
	return result, nil
}
