package config

import (
	"os"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Role 对应 roles.yaml 中的一个角色条目。
type Role struct {
	RoleID  string `yaml:"role_id"`
	Name    string `yaml:"name"`
	En      string `yaml:"en"`
	VoiceID string `yaml:"voice_id"`
	// FastVoiceID 是一句话版声音复刻返回的 FastVoiceType（如 WCHN-xxx）。
	// 填了它就用腾讯云约定值 VoiceType=200000000，并忽略 VoiceID。
	FastVoiceID string `yaml:"fast_voice_id"`
	// FallbackVoiceID 是备用音色：主音色的资源包额度用尽时顶上，
	// 避免整段对话突然没声音。留空则不降级。
	FallbackVoiceID string  `yaml:"fallback_voice_id"`
	Speed           float64 `yaml:"speed"` // TTS 语速，0 = 默认 0.9（孩子听得清一点）
	Persona         string  `yaml:"persona"`
	Catchphrase     string  `yaml:"catchphrase"`
	SayEn           string  `yaml:"say_en"`
	Hello           string  `yaml:"hello"`
}

// DefaultTTSSpeed 是没在 roles.yaml 里写 speed 时的语速。
// 4-6 岁非母语儿童对正常语速的英文连读几乎听不出来，统一放慢一档。
const DefaultTTSSpeed = 0.9

// TTSSpeed 返回该角色应该用的语速，做一次范围保护。
func (r *Role) TTSSpeed() float64 {
	if r == nil || r.Speed <= 0 {
		return DefaultTTSSpeed
	}
	return r.Speed
}

// FallbackVoiceType 返回备用音色的数字 ID；没配或格式不对时返回 0（不降级）。
func (r *Role) FallbackVoiceType() int64 {
	if r == nil {
		return 0
	}
	n, err := strconv.ParseInt(strings.TrimSpace(r.FallbackVoiceID), 10, 64)
	if err != nil || n <= 0 {
		return 0
	}
	return n
}

// RolesConfig 是 roles.yaml 的顶层结构。
type RolesConfig struct {
	Roles []Role `yaml:"roles"`
}

// LoadRoles 从指定路径读取并解析 roles.yaml。
func LoadRoles(path string) (*RolesConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg RolesConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// DailyFlowStep 是每日陪伴流程中的一步。
type DailyFlowStep struct {
	Step string `yaml:"step"`
	Text string `yaml:"text"`
}

// PromptsConfig 对应 prompts.yaml：系统提示词 + 每日陪伴流程模板。
type PromptsConfig struct {
	System struct {
		Base   string `yaml:"base"`
		Safety string `yaml:"safety"`
	} `yaml:"system"`
	DailyFlow []DailyFlowStep `yaml:"daily_flow"`
}

// GuardConfig 对应 guard.yaml：安全护栏黑名单。
type GuardConfig struct {
	BlockedWords []string `yaml:"blocked_words"`
}

// LoadPrompts 读取 prompts.yaml。
func LoadPrompts(path string) (*PromptsConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg PromptsConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// LoadGuard 读取 guard.yaml。
func LoadGuard(path string) (*GuardConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg GuardConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}
