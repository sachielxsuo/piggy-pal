package service

import "strings"

// MockReply 返回 mock 对话回复（M2 接入真实 LLM 前，供客户端联调）。
func MockReply(text string) string {
	lower := strings.ToLower(text)
	switch {
	case strings.Contains(lower, "sing") || strings.Contains(text, "唱"):
		return "好呀好呀！我们一起唱 Baa, Baa, Black Sheep 好不好？🎵"
	case strings.Contains(lower, "story") || strings.Contains(text, "故事"):
		return "那我们讲一个小猪去海边玩的故事吧～准备好了吗？"
	case strings.Contains(lower, "dinosaur") || strings.Contains(text, "恐龙"):
		return "恐龙！🦖 乔治也最喜欢恐龙啦！"
	default:
		return "That's great! 你太棒啦 ⭐"
	}
}
