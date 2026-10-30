// Package dict 提供内置英文词典：音标、中文释义、例句和真人发音。
//
// 数据全部随二进制打包（go:embed），启动时加载进内存：
//   - dict_base：ECDICT（MIT）常用词子集，清洗掉成人 / 技术义项；
//   - dict_kid：人工审校的 169 个高频童词，释义和例句按 4–6 岁改写；
//   - audio：Wiktionary / Wikimedia Commons 的真人录音（audio_words.txt，
//     约 1000 个高频儿童词），正常语速 + 0.72x 慢读。
//
// 这样查词不依赖任何外部服务，延迟只有一次网络往返。
package dict

import (
	"bufio"
	"compress/gzip"
	"embed"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"sync"
)

//go:embed data/dict_base.tsv.gz data/dict_kid.tsv.gz
var dataFS embed.FS

//go:embed data/audio
var audioFS embed.FS

// Sentence 一条中英对照句子。
type Sentence struct {
	En string `json:"en"`
	Zh string `json:"zh,omitempty"`
}

// Entry 一次查词的结果。
type Entry struct {
	Word       string    `json:"word"`
	Lemma      string    `json:"lemma"`
	PhoneticUS string    `json:"phonetic_us"`
	Senses     []string  `json:"senses"`
	Example    *Sentence `json:"example,omitempty"`
	// Context 是点击所在的原句，比通用例句更有语境。
	Context *Sentence `json:"context,omitempty"`

	AudioB64     string `json:"audio_b64,omitempty"`
	AudioSlowB64 string `json:"audio_slow_b64,omitempty"`
	AudioSource  string `json:"audio_source,omitempty"` // human / tts
	AudioCredit  string `json:"audio_credit,omitempty"` // 真人录音的署名与许可

	// Level：kid（人工审校）/ basic（ECDICT 清洗）/ enriched（LLM 补全）。
	Level string `json:"level"`
	Found bool   `json:"found"`
}

type kidEntry struct {
	word      string
	phonetic  string
	zh        string
	exampleEn string
	exampleZh string
	hasAudio  bool
}

type baseEntry struct {
	word     string
	phonetic string
	zh       []string
}

// Credit 真人发音的来源信息，展示在「关于」页和词条里。
type Credit struct {
	Title   string `json:"title"`
	Page    string `json:"page"`
	License string `json:"license"`
	Artist  string `json:"artist"`
}

// Dictionary 是加载好的内存词典，只读，并发安全。
type Dictionary struct {
	kid     map[string]kidEntry
	base    map[string]baseEntry
	forms   map[string]string // cats -> cat
	credits map[string]Credit
}

var (
	ErrNotFound  = errors.New("词典里没有这个词")
	validWordRE  = regexp.MustCompile(`^[a-z][a-z'-]{0,29}$`)
	possessiveRE = regexp.MustCompile(`'s$|’s$`)
	nonLetterRE  = regexp.MustCompile(`[^a-z']`)
)

// Load 解析内置数据。只应在启动时调用一次。
func Load() (*Dictionary, error) {
	d := &Dictionary{
		kid:     make(map[string]kidEntry, 256),
		base:    make(map[string]baseEntry, 20000),
		forms:   make(map[string]string, 20000),
		credits: make(map[string]Credit, 256),
	}
	if err := d.loadKid(); err != nil {
		return nil, err
	}
	if err := d.loadBase(); err != nil {
		return nil, err
	}
	if err := d.loadCredits(); err != nil {
		return nil, err
	}
	return d, nil
}

func (d *Dictionary) loadKid() error {
	f, err := dataFS.Open("data/dict_kid.tsv.gz")
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer zr.Close()

	sc := bufio.NewScanner(zr)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		if len(cols) < 6 {
			continue
		}
		d.kid[cols[0]] = kidEntry{
			word:      cols[0],
			phonetic:  cols[1],
			zh:        cols[2],
			exampleEn: cols[3],
			exampleZh: cols[4],
			hasAudio:  cols[5] == "1",
		}
	}
	return sc.Err()
}

func (d *Dictionary) loadBase() error {
	f, err := dataFS.Open("data/dict_base.tsv.gz")
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		return err
	}
	defer zr.Close()

	sc := bufio.NewScanner(zr)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		cols := strings.Split(sc.Text(), "\t")
		if len(cols) < 4 {
			continue
		}
		word := cols[0]
		senses := strings.Split(cols[2], "；")
		if len(senses) > 3 {
			senses = senses[:3]
		}
		d.base[word] = baseEntry{word: word, phonetic: cols[1], zh: senses}
		for _, form := range strings.Split(cols[3], ",") {
			if form != "" && form != word {
				if _, exists := d.forms[form]; !exists {
					d.forms[form] = word
				}
			}
		}
	}
	return sc.Err()
}

func (d *Dictionary) loadCredits() error {
	raw, err := audioFS.ReadFile("data/audio/credits.json")
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, &d.credits)
}

// Normalize 把用户点到的 token 规整成可查询的词：小写、去标点、去所有格。
func Normalize(raw string) string {
	w := strings.ToLower(strings.TrimSpace(raw))
	w = possessiveRE.ReplaceAllString(w, "")
	w = nonLetterRE.ReplaceAllString(w, "")
	if w == "" || strings.Contains(w, "'") {
		// 缩写（don't / it's）不在首版词库里，避免误查。
		return ""
	}
	if !validWordRE.MatchString(w) {
		return ""
	}
	return w
}

// Lookup 查询一个词，自动还原复数 / 过去式 / 进行时等词形。
func (d *Dictionary) Lookup(raw string) (*Entry, bool) {
	word := Normalize(raw)
	if word == "" {
		return nil, false
	}
	lemma := d.resolve(word)
	entry := &Entry{Word: word, Lemma: lemma, Found: true}

	if k, ok := d.kid[lemma]; ok {
		entry.PhoneticUS = k.phonetic
		entry.Senses = []string{k.zh}
		entry.Example = &Sentence{En: k.exampleEn, Zh: k.exampleZh}
		entry.Level = "kid"
		entry.AudioSource = "human"
		entry.AudioCredit = d.creditText(lemma)
		return entry, true
	}
	if b, ok := d.base[lemma]; ok {
		entry.PhoneticUS = b.phonetic
		entry.Senses = b.zh
		entry.Level = "basic"
		return entry, true
	}
	return nil, false
}

func (d *Dictionary) creditText(word string) string {
	c, ok := d.credits[word]
	if !ok {
		return ""
	}
	// Commons 的作者字段常带换行、角色前缀和重复名字（Speaker: X / Recorder: X），压成一行再展示。
	artist := strings.NewReplacer("Speaker:", " ", "Recorder:", " ", "Voice actor:", " ").Replace(c.Artist)
	fields := strings.Fields(artist)
	if len(fields) >= 2 && len(fields)%2 == 0 {
		half := len(fields) / 2
		if strings.Join(fields[:half], " ") == strings.Join(fields[half:], " ") {
			fields = fields[:half]
		}
	}
	artist = strings.Join(fields, " ")
	if len([]rune(artist)) > 40 {
		artist = string([]rune(artist)[:40]) + "…"
	}
	parts := []string{}
	if artist != "" {
		parts = append(parts, artist)
	}
	if c.License != "" {
		parts = append(parts, c.License)
	}
	parts = append(parts, "Wikimedia Commons")
	return strings.Join(parts, " · ")
}

// Audio 返回真人发音（正常 / 慢读）。没有录音时返回 ok=false，由调用方降级到 TTS。
func (d *Dictionary) Audio(word string) (normal, slow []byte, credit string, ok bool) {
	raw := Normalize(word)
	// 录音覆盖范围由 audio_words.txt 决定，和人工童词表解耦：
	// 底库词（如 giraffe）也可以有真人录音。
	// 先按原词找（socks.mp3），再退回原形（sock.mp3）。
	w := raw
	if _, has := d.credits[w]; !has {
		w = d.resolve(raw)
	}
	if _, has := d.credits[w]; !has {
		return nil, nil, "", false
	}
	normal, err := audioFS.ReadFile("data/audio/" + w + ".mp3")
	if err != nil {
		return nil, nil, "", false
	}
	slow, err = audioFS.ReadFile("data/audio/" + w + ".sl.mp3")
	if err != nil {
		slow = nil
	}
	return normal, slow, d.creditText(w), true
}

// resolve 找到原形：先查词形表，再用常见后缀规则兜底。
func (d *Dictionary) resolve(word string) string {
	// 童词优先按原词命中，避免 "morning" 被后缀规则拆成 "morn" 这类误判。
	if _, ok := d.kid[word]; ok {
		return word
	}
	// ECDICT 的 exchange 字段是最可靠的词形还原依据（cats -> cat）。
	if lemma, ok := d.forms[word]; ok && d.exists(lemma) {
		return lemma
	}
	if _, ok := d.base[word]; ok {
		return word
	}
	for _, cand := range suffixCandidates(word) {
		if d.exists(cand) {
			return cand
		}
		if lemma, ok := d.forms[cand]; ok && d.exists(lemma) {
			return lemma
		}
	}
	return word
}

func (d *Dictionary) exists(w string) bool {
	if _, ok := d.kid[w]; ok {
		return true
	}
	_, ok := d.base[w]
	return ok
}

func suffixCandidates(w string) []string {
	var out []string
	add := func(s string) {
		if s != "" && s != w {
			out = append(out, s)
		}
	}
	switch {
	case strings.HasSuffix(w, "ies") && len(w) > 4:
		add(strings.TrimSuffix(w, "ies") + "y")
	case strings.HasSuffix(w, "es") && len(w) > 3:
		add(strings.TrimSuffix(w, "es"))
		add(strings.TrimSuffix(w, "s"))
	case strings.HasSuffix(w, "s") && !strings.HasSuffix(w, "ss") && len(w) > 2:
		add(strings.TrimSuffix(w, "s"))
	}
	if strings.HasSuffix(w, "ed") && len(w) > 3 {
		add(strings.TrimSuffix(w, "ed"))
		add(strings.TrimSuffix(w, "d"))
		stem := strings.TrimSuffix(w, "ed")
		if len(stem) > 2 && stem[len(stem)-1] == stem[len(stem)-2] {
			add(stem[:len(stem)-1])
		}
	}
	if strings.HasSuffix(w, "ing") && len(w) > 4 {
		stem := strings.TrimSuffix(w, "ing")
		add(stem)
		add(stem + "e")
		if len(stem) > 2 && stem[len(stem)-1] == stem[len(stem)-2] {
			add(stem[:len(stem)-1])
		}
	}
	if strings.HasSuffix(w, "er") && len(w) > 3 {
		add(strings.TrimSuffix(w, "er"))
		add(strings.TrimSuffix(w, "r"))
	}
	if strings.HasSuffix(w, "est") && len(w) > 4 {
		add(strings.TrimSuffix(w, "est"))
		add(strings.TrimSuffix(w, "st"))
	}
	return out
}

var wordBoundaryCache sync.Map

// FindContext 从消息原文里挑出包含目标词的英文句子，并用下一行中文做对照。
// 聊天消息的格式是「英文行 + 中文行」，所以下一行通常就是它的翻译。
func FindContext(content, word string) *Sentence {
	if content == "" || word == "" {
		return nil
	}
	lines := strings.Split(content, "\n")
	clean := make([]string, 0, len(lines))
	for _, l := range lines {
		if t := strings.TrimSpace(l); t != "" {
			clean = append(clean, t)
		}
	}
	re := boundaryRegexp(word)
	for i, line := range clean {
		if !re.MatchString(line) {
			continue
		}
		s := &Sentence{En: line}
		if i+1 < len(clean) && hasCJK(clean[i+1]) {
			s.Zh = clean[i+1]
		} else if hasCJK(line) {
			// 中英混排时拆出英文片段
			if en := firstEnglishRun(line); en != "" {
				s.En = en
			}
		}
		return s
	}
	return nil
}

func boundaryRegexp(word string) *regexp.Regexp {
	if v, ok := wordBoundaryCache.Load(word); ok {
		return v.(*regexp.Regexp)
	}
	re := regexp.MustCompile(`(?i)\b` + regexp.QuoteMeta(word) + `\b`)
	wordBoundaryCache.Store(word, re)
	return re
}

func hasCJK(s string) bool {
	for _, r := range s {
		if r >= 0x4E00 && r <= 0x9FFF {
			return true
		}
	}
	return false
}

var englishRunRE = regexp.MustCompile(`[A-Za-z][A-Za-z ,.'!?-]*`)

func firstEnglishRun(s string) string {
	return strings.TrimSpace(englishRunRE.FindString(s))
}

// ReadAll 便于测试加载内嵌数据。
func ReadAll(name string) ([]byte, error) {
	f, err := dataFS.Open(name)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(f)
}

// Stats 返回词典规模，用于启动日志：人工童词 / 底库词 / 真人录音词。
func (d *Dictionary) Stats() (kid, base, audio int) {
	return len(d.kid), len(d.base), len(d.credits)
}
