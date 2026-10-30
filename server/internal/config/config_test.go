package config

import (
	"strings"
	"testing"
)

func TestRoleFallbackVoiceType(t *testing.T) {
	cases := []struct {
		name string
		role *Role
		want int64
	}{
		{"没配置", &Role{VoiceID: "403000"}, 0},
		{"正常数字", &Role{VoiceID: "403000", FallbackVoiceID: "101016"}, 101016},
		{"带空格", &Role{FallbackVoiceID: " 101015 "}, 101015},
		{"非法值", &Role{FallbackVoiceID: "zhitian"}, 0},
		{"零", &Role{FallbackVoiceID: "0"}, 0},
		{"负数", &Role{FallbackVoiceID: "-1"}, 0},
		{"角色为空", nil, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.role.FallbackVoiceType(); got != c.want {
				t.Errorf("FallbackVoiceType() = %d, want %d", got, c.want)
			}
		})
	}
}

// 线上 roles.yaml 必须给每个角色配备用音色，否则资源包一用完就静音。
func TestRolesYAMLHasFallbackVoice(t *testing.T) {
	cfg, err := LoadRoles("../../config/roles.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Roles) == 0 {
		t.Fatal("roles.yaml 里没有角色")
	}
	for _, r := range cfg.Roles {
		if r.VoiceID == "" {
			t.Errorf("%s 没有 voice_id", r.RoleID)
		}
		if r.FallbackVoiceType() == 0 {
			t.Errorf("%s 没有配 fallback_voice_id（资源包用尽时会静音）", r.RoleID)
		}
		if strings.TrimSpace(r.FallbackVoiceID) == strings.TrimSpace(r.VoiceID) {
			t.Errorf("%s 的备用音色和主音色一样，降级没有意义", r.RoleID)
		}
	}
}
