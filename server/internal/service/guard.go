package service

import (
	"strings"

	"piggy-pal/server/internal/config"
)

// GuardService 安全护栏：命中黑名单则替换话题，不批评不放大。
type GuardService struct {
	blocked []string
}

// NewGuardService 从 guard.yaml 构造。
func NewGuardService(cfg *config.GuardConfig) *GuardService {
	if cfg == nil {
		return &GuardService{}
	}
	return &GuardService{blocked: cfg.BlockedWords}
}

// ContainsBlocked 判断文本是否命中黑名单。
func (g *GuardService) ContainsBlocked(text string) bool {
	for _, w := range g.blocked {
		if w != "" && strings.Contains(text, w) {
			return true
		}
	}
	return false
}
