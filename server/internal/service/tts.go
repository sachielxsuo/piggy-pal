package service

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode"

	"github.com/google/uuid"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common"
	sdkerrors "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/errors"
	"github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/profile"
	tts "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/tts/v20190823"
)

// ErrVoiceExhausted 表示这个音色的资源包额度用完了（腾讯云 UnsupportedOperation.PkgExhausted）。
// 上层拿到它应该换备用音色，而不是把错误抛给孩子。
var ErrVoiceExhausted = errors.New("TTS 音色资源包额度已用尽")

// exhaustedCooldown 是额度用尽后的静默期：这段时间内不再打腾讯云，
// 直接换备用音色，避免每句话都白等一次失败请求。
const exhaustedCooldown = 10 * time.Minute

// 腾讯云基础语音合成的单次请求上限（官方文档「基础语音合成」Text 参数）：
//   - 中文（含全角标点）最多 150 个汉字
//   - 英文（含半角标点）最多 500 个字母
//
// 超了直接返回 UnsupportedOperation.TextTooLong，这一段就静音了。当前策略是
// 不改行为、只观测：每次请求都记下用量，接近上限先告警，真的被拒再单独记一条。
const (
	ttsMaxCJK   = 150
	ttsMaxLatin = 500

	// ttsWarnRatio 用量到这个比例就先 WARN，用来在「真的失败」之前看到趋势。
	ttsWarnRatio = 0.8
)

// ttsTooLongCount 进程内累计「文本超长被拒」的次数，写进日志方便和 grep 对账。
var ttsTooLongCount atomic.Int64

// textUnitUsage 按腾讯云的额度口径统计文本用量：汉字（含全角标点）算 1 个「汉字」，
// 英文 / 数字 / 半角标点算 1 个「字母」，空白不计。
// 纯中文和纯英文的额度是分开的两条线，混排没有官方口径，调用方用 ttsQuotaRatio 估算。
func textUnitUsage(text string) (cjk, latin int) {
	for _, r := range text {
		switch {
		case unicode.Is(unicode.Han, r), isFullWidthRune(r):
			cjk++
		case r == ' ' || r == '\n' || r == '\r' || r == '\t':
			// 空白不计
		case r < unicode.MaxASCII:
			latin++
		default:
			// 其它符号（emoji 等）按一个汉字算，宁可高估
			cjk++
		}
	}
	return cjk, latin
}

// isFullWidthRune 判断全角标点 / 全角字符，按官方口径算一个汉字。
func isFullWidthRune(r rune) bool {
	return (r >= 0x3000 && r <= 0x303F) ||
		(r >= 0xFF00 && r <= 0xFFEF) ||
		r == '…' || r == '“' || r == '”' || r == '‘' || r == '’'
}

// ttsQuotaRatio 估算用量占单次上限的比例：>1 基本一定会被拒，>=0.8 就该留意了。
// 混排取两条线相加，属于保守估计；日志里同时记了 cjk / latin 原始值，方便回头校准。
func ttsQuotaRatio(cjk, latin int) float64 {
	return float64(cjk)/ttsMaxCJK + float64(latin)/ttsMaxLatin
}

// isTextTooLong 判断是不是「文本超过单次长度上限」。
func isTextTooLong(err error) bool {
	if err == nil {
		return false
	}
	var sdkErr *sdkerrors.TencentCloudSDKError
	if errors.As(err, &sdkErr) {
		return strings.Contains(sdkErr.Code, "TextTooLong")
	}
	return strings.Contains(err.Error(), "TextTooLong")
}

// TTSService 封装腾讯云语音合成，按「文本+音色」hash 落盘缓存，重复话术直接命中省成本。
type TTSService struct {
	secretID  string
	secretKey string
	region    string
	cacheDir  string

	mu sync.Mutex
	// exhausted 记录「这个音色在什么时候之前不用再试」
	exhausted map[int64]time.Time
}

// NewTTSService 构造 TTS 服务。
func NewTTSService(secretID, secretKey, region, cacheDir string) *TTSService {
	return &TTSService{
		secretID:  secretID,
		secretKey: secretKey,
		region:    region,
		cacheDir:  cacheDir,
		exhausted: map[int64]time.Time{},
	}
}

// Enabled 是否已配置 CAM 密钥。
func (s *TTSService) Enabled() bool { return s.secretID != "" && s.secretKey != "" }

// Synthesize 合成 mp3 音频，返回 base64。带磁盘缓存。
// speed 是语速（0.6–2.0），<=0 时按 1.0 处理；缓存键包含语速，
// 调慢语速后不会错误命中旧音频。
//
// fastVoiceType 是一句话版声音复刻的音色 ID（WCHN-xxx）。
// 非空时腾讯云要求 VoiceType 固定为 200000000，实际音色由 FastVoiceType 指定。
func (s *TTSService) Synthesize(text string, voiceType int64, fastVoiceType string, speed float64) (string, error) {
	if !s.Enabled() {
		return "", fmt.Errorf("CAM 密钥未配置")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return "", fmt.Errorf("合成文本为空")
	}
	if speed <= 0 {
		speed = 1.0
	}
	if speed < 0.6 {
		speed = 0.6
	}
	if speed > 2.0 {
		speed = 2.0
	}

	cacheFile := s.cachePath(text, voiceType, fastVoiceType, speed)
	if b64, ok := s.readCache(cacheFile); ok {
		slog.Info("TTS 命中缓存", "text_len", len(text), "voice_type", voiceType,
			"fast_voice_type", fastVoiceType, "speed", speed)
		return b64, nil
	}

	if s.voiceExhausted(voiceType) {
		return "", fmt.Errorf("%w（voice_type=%d）", ErrVoiceExhausted, voiceType)
	}

	// 长度用量：每次请求都记，方便日后判断「是不是越来越接近上限」。
	cjk, latin := textUnitUsage(text)
	ratio := ttsQuotaRatio(cjk, latin)
	if ratio >= ttsWarnRatio {
		slog.Warn("TTS 文本接近单次长度上限",
			"cjk", cjk, "latin", latin,
			"limit_cjk", ttsMaxCJK, "limit_latin", ttsMaxLatin,
			"quota_ratio", fmt.Sprintf("%.2f", ratio),
			"text_head", truncateRunes(text, 30))
	}

	start := time.Now()
	slog.Info("TTS 请求开始", "text_len", len(text), "cjk", cjk, "latin", latin,
		"quota_ratio", fmt.Sprintf("%.2f", ratio),
		"voice_type", voiceType, "fast_voice_type", fastVoiceType, "speed", speed)

	credential := common.NewCredential(s.secretID, s.secretKey)
	cpf := profile.NewClientProfile()
	client, err := tts.NewClient(credential, s.region, cpf)
	if err != nil {
		return "", err
	}

	request := tts.NewTextToVoiceRequest()
	request.Text = common.StringPtr(text)
	request.VoiceType = common.Int64Ptr(voiceType)
	if fastVoiceType != "" {
		request.FastVoiceType = common.StringPtr(fastVoiceType)
	}
	request.Codec = common.StringPtr("mp3")
	request.SampleRate = common.Uint64Ptr(16000)
	request.Speed = common.Float64Ptr(speed)
	request.SessionId = common.StringPtr(uuid.NewString())

	resp, err := client.TextToVoice(request)
	if err != nil {
		cost := time.Since(start).Milliseconds()
		if isTextTooLong(err) {
			// 单独一条、固定文案：`grep "文本超出长度限制"` 就能数出到底有没有命中。
			// text_head 用来分辨是哪条内容（睡前故事 / 开场白 / 聊天某一句）。
			hits := ttsTooLongCount.Add(1)
			slog.Error("TTS 文本超出长度限制，这一段会被跳过",
				"cjk", cjk, "latin", latin,
				"limit_cjk", ttsMaxCJK, "limit_latin", ttsMaxLatin,
				"text_len", len(text), "voice_type", voiceType, "speed", speed,
				"total_hits", hits, "text_head", truncateRunes(text, 30),
				"cost_ms", cost, "err", err)
		} else {
			slog.Error("TTS 调用失败", "err", err, "cost_ms", cost)
		}
		if isQuotaExhausted(err) {
			s.markExhausted(voiceType)
			return "", fmt.Errorf("%w: %v", ErrVoiceExhausted, err)
		}
		return "", err
	}

	audio := ""
	if resp.Response != nil && resp.Response.Audio != nil {
		audio = *resp.Response.Audio
	}
	if audio == "" {
		slog.Warn("TTS 返回空音频", "cost_ms", time.Since(start).Milliseconds())
		return "", fmt.Errorf("TTS 返回空音频")
	}

	// 落盘缓存（best effort，失败不影响返回）
	if data, err := base64.StdEncoding.DecodeString(audio); err == nil {
		_ = os.MkdirAll(s.cacheDir, 0o755)
		_ = os.WriteFile(cacheFile, data, 0o644)
		slog.Info("TTS 请求完成", "audio_bytes", len(data), "cost_ms", time.Since(start).Milliseconds())
	} else {
		slog.Warn("TTS 音频落盘缓存失败", "err", err)
	}
	return audio, nil
}

// SynthesizeWithFallback 先试主音色；资源包用尽时自动改用备用音色，
// 孩子那边只是换了个声音，不会整段对话静音。
func (s *TTSService) SynthesizeWithFallback(
	text string, voiceType int64, fastVoiceType string, speed float64, fallbackVoiceType int64,
) (string, error) {
	audio, err := s.Synthesize(text, voiceType, fastVoiceType, speed)
	if err == nil || fallbackVoiceType <= 0 || fallbackVoiceType == voiceType ||
		!errors.Is(err, ErrVoiceExhausted) {
		return audio, err
	}
	slog.Warn("主音色资源包已用尽，改用备用音色",
		"voice_type", voiceType, "fallback_voice_type", fallbackVoiceType)
	return s.Synthesize(text, fallbackVoiceType, "", speed)
}

func (s *TTSService) voiceExhausted(voiceType int64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	until, ok := s.exhausted[voiceType]
	if !ok {
		return false
	}
	if time.Now().After(until) {
		delete(s.exhausted, voiceType)
		return false
	}
	return true
}

func (s *TTSService) markExhausted(voiceType int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.exhausted == nil {
		s.exhausted = map[int64]time.Time{}
	}
	if _, ok := s.exhausted[voiceType]; !ok {
		slog.Error("TTS 音色资源包额度已用尽，先换备用音色，请尽快续费",
			"voice_type", voiceType, "cooldown", exhaustedCooldown.String())
	}
	s.exhausted[voiceType] = time.Now().Add(exhaustedCooldown)
}

// isQuotaExhausted 判断是不是「资源包用完了」这类错误。
func isQuotaExhausted(err error) bool {
	if err == nil {
		return false
	}
	var sdkErr *sdkerrors.TencentCloudSDKError
	if errors.As(err, &sdkErr) {
		return isQuotaCode(sdkErr.Code)
	}
	msg := err.Error()
	return strings.Contains(msg, "PkgExhausted") || strings.Contains(msg, "NoFreeAmount")
}

func isQuotaCode(code string) bool {
	switch code {
	case "UnsupportedOperation.PkgExhausted", "FailedOperation.NoFreeAmount":
		return true
	}
	return strings.Contains(code, "PkgExhausted")
}

func (s *TTSService) cachePath(text string, voiceType int64, fastVoiceType string, speed float64) string {
	// 普通音色沿用旧键格式，避免这次发版把已有 TTS 缓存全部判为 miss、重新合成一遍。
	var key string
	if fastVoiceType == "" {
		key = fmt.Sprintf("%d|%.2f|%s", voiceType, speed, text)
	} else {
		key = fmt.Sprintf("%d|%s|%.2f|%s", voiceType, fastVoiceType, speed, text)
	}
	h := sha256.Sum256([]byte(key))
	return filepath.Join(s.cacheDir, hex.EncodeToString(h[:])+".mp3")
}

func (s *TTSService) readCache(path string) (string, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return base64.StdEncoding.EncodeToString(data), true
}
