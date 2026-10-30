package dict

import "testing"

func TestLoadAndStats(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	kid, base, audio := d.Stats()
	if kid != 169 {
		t.Errorf("kid = %d, want 169", kid)
	}
	if base < 14000 {
		t.Errorf("base = %d, want >= 14000", base)
	}
	if audio < 950 {
		t.Errorf("audio = %d, want >= 950（录音词表约 1000 词）", audio)
	}
}

func TestLookupKidWord(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	e, ok := d.Lookup("dinosaur")
	if !ok {
		t.Fatal("dinosaur 应该能查到")
	}
	if e.Level != "kid" {
		t.Errorf("level = %q, want kid", e.Level)
	}
	if len(e.Senses) != 1 || e.Senses[0] != "恐龙" {
		t.Errorf("senses = %v", e.Senses)
	}
	if e.PhoneticUS == "" || e.PhoneticUS[0] != '/' {
		t.Errorf("phonetic = %q，应该是 IPA", e.PhoneticUS)
	}
	if e.Example == nil || e.Example.En == "" || e.Example.Zh == "" {
		t.Errorf("example = %+v", e.Example)
	}
	if e.AudioSource != "human" {
		t.Errorf("audio_source = %q, want human", e.AudioSource)
	}
	if e.AudioCredit == "" {
		t.Error("真人录音必须带署名")
	}
}

func TestLookupInflections(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		"cats":        "cat",
		"apples":      "apple",
		"jumped":      "jump",
		"jumping":     "jump",
		"running":     "run",
		"boxes":       "box",
		"babies":      "baby",
		"bigger":      "big",
		"CAT":         "cat",
		"cat!":        "cat",
		"cat's":       "cat",
		"dancers":     "dancer",
		"stopped":     "stop",
		"butterflies": "butterfly",
		"morning":     "morning",
		"news":        "news",
		"glass":       "glass",
	}
	for raw, want := range cases {
		e, ok := d.Lookup(raw)
		if !ok {
			t.Errorf("Lookup(%q) 没查到", raw)
			continue
		}
		if e.Lemma != want {
			t.Errorf("Lookup(%q).Lemma = %q, want %q", raw, e.Lemma, want)
		}
	}
}

func TestLookupBaseWord(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	e, ok := d.Lookup("telescope")
	if !ok {
		t.Fatal("telescope 应该在 ECDICT 底库里")
	}
	if e.Level != "basic" {
		t.Errorf("level = %q, want basic", e.Level)
	}
	if len(e.Senses) == 0 || e.Senses[0] == "" {
		t.Errorf("senses = %v", e.Senses)
	}
	for _, s := range e.Senses {
		if containsAny(s, "计算机", "恶妇", "性交", "枪") {
			t.Errorf("释义里混进了成人/技术义项：%q", s)
		}
	}
}

func TestLookupInvalid(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	for _, raw := range []string{"", "  ", "123", "don't", "中文", "--"} {
		if _, ok := d.Lookup(raw); ok {
			t.Errorf("Lookup(%q) 不该命中", raw)
		}
	}
	if _, ok := d.Lookup("zzzzzz"); ok {
		t.Error("不存在的词不该命中")
	}
}

func TestAudio(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	normal, slow, credit, ok := d.Audio("apple")
	if !ok {
		t.Fatal("apple 应该有真人发音")
	}
	if len(normal) < 1000 || len(slow) < 1000 {
		t.Errorf("音频太小：normal=%d slow=%d", len(normal), len(slow))
	}
	if credit == "" {
		t.Error("缺少署名信息")
	}
	if _, _, _, ok := d.Audio("telescope"); ok {
		t.Error("telescope 没有录音，应该返回 false 让上层走 TTS")
	}
}

// 录音和人工童词表解耦后，底库词也应该能拿到真人录音。
func TestAudioForBaseWord(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	normal, slow, credit, ok := d.Audio("giraffe")
	if !ok {
		t.Fatal("giraffe 应该有真人录音")
	}
	if len(normal) < 1000 || len(slow) < 1000 {
		t.Errorf("音频太小：normal=%d slow=%d", len(normal), len(slow))
	}
	if credit == "" {
		t.Error("缺少署名")
	}
}

// 复数形式的录音要能命中自己那份（socks.mp3），而不是被还原成单数后丢录音。
func TestAudioInflectedForm(t *testing.T) {
	d, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, _, ok := d.Audio("socks"); !ok {
		t.Error("socks 应该能拿到录音")
	}
}

func TestFindContext(t *testing.T) {
	got := FindContext("Look, a dinosaur!\n看，一只恐龙！", "dinosaur")
	if got == nil {
		t.Fatal("应该找到原句")
	}
	if got.En != "Look, a dinosaur!" || got.Zh != "看，一只恐龙！" {
		t.Errorf("context = %+v", got)
	}
	if got := FindContext("The cat is sleeping.\n小猫在睡觉。", "dinosaur"); got != nil {
		t.Errorf("不该命中别的句子：%+v", got)
	}
}

func TestNormalize(t *testing.T) {
	cases := map[string]string{
		"Dinosaur,": "dinosaur",
		"cat's":     "cat",
		"  Dog ":    "dog",
		"don't":     "",
		"":          "",
	}
	for raw, want := range cases {
		if got := Normalize(raw); got != want {
			t.Errorf("Normalize(%q) = %q, want %q", raw, got, want)
		}
	}
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if len(sub) > 0 && len(s) >= len(sub) {
			for i := 0; i+len(sub) <= len(s); i++ {
				if s[i:i+len(sub)] == sub {
					return true
				}
			}
		}
	}
	return false
}
