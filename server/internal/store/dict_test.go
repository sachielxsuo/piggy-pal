package store

import (
	"testing"

	"piggy-pal/server/internal/model"
)

func TestDictEnrichmentRoundTrip(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()

	if got, err := s.GetDictEnrichment("triceratops"); err != nil || got != nil {
		t.Fatalf("空库应该返回 nil, nil，实际 %v, %v", got, err)
	}

	want := &model.DictEnrichment{
		Word: "triceratops", Zh: "三角龙",
		ExampleEn: "The triceratops has three horns.", ExampleZh: "三角龙有三只角。",
	}
	if err := s.SaveDictEnrichment(want); err != nil {
		t.Fatalf("保存: %v", err)
	}
	got, err := s.GetDictEnrichment("triceratops")
	if err != nil || got == nil {
		t.Fatalf("读取: %v, %v", got, err)
	}
	if got.Zh != want.Zh || got.ExampleEn != want.ExampleEn || got.ExampleZh != want.ExampleZh {
		t.Errorf("got = %+v", got)
	}
	if got.CreatedAt == "" {
		t.Error("created_at 应该自动补齐")
	}

	// 重复写入要覆盖而不是报错
	want.Zh = "三角恐龙"
	if err := s.SaveDictEnrichment(want); err != nil {
		t.Fatalf("覆盖: %v", err)
	}
	got, _ = s.GetDictEnrichment("triceratops")
	if got.Zh != "三角恐龙" {
		t.Errorf("覆盖后 zh = %q", got.Zh)
	}
}
