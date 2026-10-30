package service

import (
	"errors"
	"fmt"
	"testing"
	"time"

	sdkerrors "github.com/tencentcloud/tencentcloud-sdk-go/tencentcloud/common/errors"

	"piggy-pal/server/internal/config"
)

// 资源包用尽时不能当成普通错误往上抛，否则整段对话会静音。
func TestIsQuotaExhausted(t *testing.T) {
	sdkErr := sdkerrors.NewTencentCloudSDKError(
		"UnsupportedOperation.PkgExhausted",
		"The resource pack allowance has been exhausted, please check your resource pack.",
		"req-1",
	)
	if !isQuotaExhausted(sdkErr) {
		t.Error("PkgExhausted 应该识别为额度用尽")
	}
	if !isQuotaExhausted(fmt.Errorf("包装一层: %w", sdkErr)) {
		t.Error("包一层之后也要能识别")
	}
	if !isQuotaExhausted(errors.New("something PkgExhausted something")) {
		t.Error("纯字符串里的 PkgExhausted 也要兜住")
	}
	for _, code := range []string{"FailedOperation.NoFreeAmount"} {
		if !isQuotaExhausted(sdkerrors.NewTencentCloudSDKError(code, "no free amount", "req-2")) {
			t.Errorf("%s 应该识别为额度用尽", code)
		}
	}
	if isQuotaExhausted(nil) {
		t.Error("nil 不是额度用尽")
	}
	if isQuotaExhausted(sdkerrors.NewTencentCloudSDKError("FailedOperation.InternalError", "boom", "req-3")) {
		t.Error("其它错误不该被当成额度用尽")
	}
}

// 额度用尽后要有一段时间的静默期，避免每句话都去打一次必然失败的接口。
func TestVoiceExhaustedCooldown(t *testing.T) {
	s := NewTTSService("", "", "", t.TempDir())
	if s.voiceExhausted(403000) {
		t.Fatal("刚创建时不该处于静默期")
	}
	s.markExhausted(403000)
	if !s.voiceExhausted(403000) {
		t.Error("标记之后应该处于静默期")
	}
	if s.voiceExhausted(502007) {
		t.Error("静默期只影响出问题的音色")
	}

	// 过期后自动解除
	s.mu.Lock()
	s.exhausted[403000] = time.Now().Add(-time.Second)
	s.mu.Unlock()
	if s.voiceExhausted(403000) {
		t.Error("静默期过了应该重新尝试")
	}
}

// 静默期内的请求直接返回 ErrVoiceExhausted，不发起网络调用（密钥为空也能复现）。
func TestSynthesizeFailsFastWhenExhausted(t *testing.T) {
	s := NewTTSService("id", "key", "ap-guangzhou", t.TempDir())
	s.markExhausted(403000)

	_, err := s.Synthesize("hello", 403000, "", 0.9)
	if !errors.Is(err, ErrVoiceExhausted) {
		t.Fatalf("err = %v，want ErrVoiceExhausted", err)
	}
}

// 没配备用音色 / 备用音色和主音色相同时，保持原来的错误，不做无意义的降级。
func TestSynthesizeWithFallbackSkipsWhenNoFallback(t *testing.T) {
	s := NewTTSService("id", "key", "ap-guangzhou", t.TempDir())
	s.markExhausted(403000)

	for _, fb := range []int64{0, 403000} {
		_, err := s.SynthesizeWithFallback("hello", 403000, "", 0.9, fb)
		if !errors.Is(err, ErrVoiceExhausted) {
			t.Errorf("fallback=%d 时 err = %v，want ErrVoiceExhausted", fb, err)
		}
	}
}

// 慢速重播：倍率要真的把语速降下来，又不能被夹到 TTS 不认识的值。
func TestRoleSpeed(t *testing.T) {
	peppa := &config.Role{Name: "佩奇", Speed: 0.9}
	if got := roleSpeed(peppa, 1.0); got != 0.9 {
		t.Errorf("正常语速 = %v，want 0.9", got)
	}
	if got := roleSpeed(peppa, slowSpeedFactor); got < 0.65 || got > 0.70 {
		t.Errorf("慢速 = %v，应该落在 0.65~0.70（0.9×0.75）", got)
	}
	// 角色本身语速偏低时，再乘倍率也不能掉到 TTS 下限 0.6 以下
	if got := roleSpeed(&config.Role{Speed: 0.6}, 0.5); got != 0.6 {
		t.Errorf("低于下限应夹到 0.6，得到 %v", got)
	}
	if got := roleSpeed(nil, 1.0); got != config.DefaultTTSSpeed {
		t.Errorf("空角色应回退默认语速 %v，得到 %v", config.DefaultTTSSpeed, got)
	}
}

// 长度用量按腾讯云的口径统计：汉字（含全角标点）算 1，英文/半角标点算 1，空白不计。
func TestTextUnitUsage(t *testing.T) {
	cases := []struct {
		name             string
		text             string
		wantCJK, wantLat int
	}{
		{"纯中文", "你好世界", 4, 0},
		{"中文全角标点算一个汉字", "你好，世界！", 6, 0},
		{"纯英文", "Hello, world!", 0, 12},
		{"空白不计", "a b\tc\nd", 0, 4},
		{"中英混排", "晚安，Mike。", 4, 4},
		{"数字算字母", "123", 0, 3},
		{"emoji 按汉字高估", "🌙", 1, 0},
		{"空串", "", 0, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cjk, latin := textUnitUsage(tc.text)
			if cjk != tc.wantCJK || latin != tc.wantLat {
				t.Fatalf("textUnitUsage(%q) = (%d, %d), want (%d, %d)",
					tc.text, cjk, latin, tc.wantCJK, tc.wantLat)
			}
		})
	}
}

// 额度比例：150 汉字或 500 字母就算满，混排相加，方便在真失败之前告警。
func TestTTSQuotaRatio(t *testing.T) {
	if got := ttsQuotaRatio(0, 0); got != 0 {
		t.Errorf("空文本比例 = %v, want 0", got)
	}
	if got := ttsQuotaRatio(ttsMaxCJK, 0); got != 1 {
		t.Errorf("150 汉字比例 = %v, want 1", got)
	}
	if got := ttsQuotaRatio(0, ttsMaxLatin); got != 1 {
		t.Errorf("500 字母比例 = %v, want 1", got)
	}
	if got := ttsQuotaRatio(75, 250); got != 1 {
		t.Errorf("混排各占一半比例 = %v, want 1", got)
	}
	// 线上真实故事：162 字母 + 8 汉字，应该远低于告警线
	if got := ttsQuotaRatio(8, 162); got >= ttsWarnRatio {
		t.Errorf("当前故事长度不该触发告警，比例 = %v", got)
	}
}

// 超长错误要能被单独识别出来，才能记成一条可 grep 的日志，而不是混在「调用失败」里。
func TestIsTextTooLong(t *testing.T) {
	if !isTextTooLong(sdkerrors.NewTencentCloudSDKError(
		"UnsupportedOperation.TextTooLong", "text too long", "req-1")) {
		t.Error("TextTooLong 应该被识别")
	}
	if !isTextTooLong(fmt.Errorf("包装: %w", sdkerrors.NewTencentCloudSDKError(
		"UnsupportedOperation.TextTooLong", "text too long", "req-2"))) {
		t.Error("包一层之后也要能识别")
	}
	if !isTextTooLong(errors.New("...TextTooLong...")) {
		t.Error("纯字符串也要兜住")
	}
	if isTextTooLong(nil) {
		t.Error("nil 不是超长")
	}
	if isTextTooLong(sdkerrors.NewTencentCloudSDKError(
		"FailedOperation.InternalError", "boom", "req-3")) {
		t.Error("其它错误不该被当成超长")
	}
	if isTextTooLong(sdkerrors.NewTencentCloudSDKError(
		"UnsupportedOperation.PkgExhausted", "no quota", "req-4")) {
		t.Error("额度用尽不该被当成超长")
	}
}
