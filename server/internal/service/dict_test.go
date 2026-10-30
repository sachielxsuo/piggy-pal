package service

import (
	"context"
	"testing"

	"piggy-pal/server/internal/model"
	"piggy-pal/server/internal/store"
)

func TestLookupWordKidEntry(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	entry, err := chat.LookupWord(context.Background(), "anan", "peppa", "Dinosaur!", 0)
	if err != nil {
		t.Fatalf("LookupWord: %v", err)
	}
	if !entry.Found || entry.Lemma != "dinosaur" || entry.Level != "kid" {
		t.Fatalf("entry = %+v", entry)
	}
	if entry.AudioSource != "human" {
		t.Errorf("audio_source = %q，童词应该用真人录音", entry.AudioSource)
	}
	if entry.AudioB64 == "" || entry.AudioSlowB64 == "" {
		t.Error("真人录音应该同时返回正常和慢读")
	}
	if entry.AudioCredit == "" {
		t.Error("真人录音必须带署名")
	}
}

func TestLookupWordContextFromMessage(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	msg := &model.ChatMessage{
		ChildID: "anan", RoleID: "peppa", Speaker: "ai",
		Content: "Look, a dinosaur!\n看，一只恐龙！",
	}
	if err := st.SaveMessage(msg); err != nil {
		t.Fatal(err)
	}
	chat := newMockChatService(t, st)

	entry, err := chat.LookupWord(context.Background(), "anan", "peppa", "dinosaur", msg.ID)
	if err != nil {
		t.Fatalf("LookupWord: %v", err)
	}
	if entry.Context == nil {
		t.Fatal("应该带上点击所在的原句")
	}
	if entry.Context.En != "Look, a dinosaur!" || entry.Context.Zh != "看，一只恐龙！" {
		t.Errorf("context = %+v", entry.Context)
	}
}

func TestLookupWordContextIgnoresOtherChild(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	msg := &model.ChatMessage{ChildID: "other", RoleID: "peppa", Speaker: "ai", Content: "Look, a dinosaur!"}
	if err := st.SaveMessage(msg); err != nil {
		t.Fatal(err)
	}
	chat := newMockChatService(t, st)

	entry, err := chat.LookupWord(context.Background(), "anan", "peppa", "dinosaur", msg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Context != nil {
		t.Error("不能读到别的宝宝的消息")
	}
}

func TestLookupWordBaseAndUnknown(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	base, err := chat.LookupWord(context.Background(), "anan", "peppa", "telescope", 0)
	if err != nil {
		t.Fatal(err)
	}
	if !base.Found || base.Level != "basic" {
		t.Errorf("telescope = %+v", base)
	}
	if base.AudioSource != "" {
		t.Errorf("没有录音且 TTS 关闭时 audio_source 应为空，实际 %q", base.AudioSource)
	}

	unknown, err := chat.LookupWord(context.Background(), "anan", "peppa", "zzzzzz", 0)
	if err != nil {
		t.Fatal(err)
	}
	if unknown.Found {
		t.Error("词库里没有、LLM 又关闭时应该 found=false")
	}

	if _, err := chat.LookupWord(context.Background(), "anan", "peppa", "don't", 0); err == nil {
		t.Error("缩写应该被拒绝")
	}
}

// 录音词表扩到 1000 词后，底库词（非人工童词）也应该走真人录音。
func TestLookupBaseWordWithHumanAudio(t *testing.T) {
	st, err := store.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	chat := newMockChatService(t, st)

	entry, err := chat.LookupWord(context.Background(), "anan", "peppa", "giraffe", 0)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Level != "basic" {
		t.Errorf("level = %q, want basic", entry.Level)
	}
	if entry.AudioSource != "human" {
		t.Errorf("audio_source = %q，want human", entry.AudioSource)
	}
	if entry.AudioB64 == "" || entry.AudioSlowB64 == "" {
		t.Error("真人录音应该同时返回正常和慢读")
	}
}
