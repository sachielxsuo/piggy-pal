package service

import (
	"context"

	"piggy-pal/server/internal/model"
)

// stickerDef 贴纸目录：按累计星星解锁，不需要消费星星。
// 只增不减，孩子攒到的星星永远属于自己，避免「花掉之后成就消失」的挫败感。
type stickerDef struct {
	ID    string
	Emoji string
	Name  string
	Hint  string
	Stars int
}

var stickerCatalog = []stickerDef{
	{"star", "⭐", "小星星", "第一次攒到 10 颗星，你真棒！", 10},
	{"rainbow", "🌈", "彩虹", "说出来，世界就变彩色啦。", 25},
	{"dino", "🦖", "小恐龙", "Dine-saw! 乔治最喜欢你啦。", 50},
	{"piggy", "🐷", "小猪玩伴", "你已经是玩伴的好朋友了。", 80},
	{"rocket", "🚀", "小火箭", "每天开口，就能飞到更远的地方。", 120},
	{"unicorn", "🦄", "独角兽", "会说英语的小朋友最闪亮。", 170},
	{"ocean", "🐠", "海底世界", "像小鱼一样，自由自在地说。", 230},
	{"planet", "🪐", "小星球", "你的声音已经传到星星那里啦。", 300},
	{"castle", "🏰", "魔法城堡", "坚持每天聊一聊，城堡就开门。", 400},
	{"hero", "🦸", "超级小英雄", "你就是自己故事里的英雄！", 550},
}

// StickerBoard 返回贴纸墙：累计星星、每张贴纸是否解锁、下一张待解锁贴纸。
func (s *ChatService) StickerBoard(ctx context.Context, childID string) (*model.StickerBoard, error) {
	total, err := s.store.TotalStars(childID)
	if err != nil {
		return nil, err
	}
	board := &model.StickerBoard{
		ChildID:    childID,
		TotalStars: total,
		Stickers:   make([]model.Sticker, 0, len(stickerCatalog)),
	}
	for _, d := range stickerCatalog {
		st := model.Sticker{
			ID:       d.ID,
			Emoji:    d.Emoji,
			Name:     d.Name,
			Hint:     d.Hint,
			Stars:    d.Stars,
			Unlocked: total >= d.Stars,
		}
		if !st.Unlocked && board.Next == nil {
			next := st
			board.Next = &next
		}
		board.Stickers = append(board.Stickers, st)
	}
	return board, nil
}
