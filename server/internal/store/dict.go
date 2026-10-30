package store

import (
	"database/sql"
	"errors"
	"time"

	"piggy-pal/server/internal/model"
)

// GetDictEnrichment 读取某个长尾词的补全结果，没有时返回 nil, nil。
func (s *Store) GetDictEnrichment(word string) (*model.DictEnrichment, error) {
	row := s.db.QueryRow(`SELECT word, zh, example_en, example_zh, created_at
		FROM dict_enrichment WHERE word = ?`, word)
	var e model.DictEnrichment
	var en, zh, created sql.NullString
	err := row.Scan(&e.Word, &e.Zh, &en, &zh, &created)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	e.ExampleEn = en.String
	e.ExampleZh = zh.String
	e.CreatedAt = created.String
	return &e, nil
}

// SaveDictEnrichment 写入（或覆盖）一个长尾词的补全结果。
func (s *Store) SaveDictEnrichment(e *model.DictEnrichment) error {
	if e.CreatedAt == "" {
		e.CreatedAt = time.Now().Format(time.RFC3339)
	}
	_, err := s.db.Exec(`INSERT INTO dict_enrichment (word, zh, example_en, example_zh, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(word) DO UPDATE SET
			zh = excluded.zh, example_en = excluded.example_en,
			example_zh = excluded.example_zh, created_at = excluded.created_at`,
		e.Word, e.Zh, e.ExampleEn, e.ExampleZh, e.CreatedAt)
	return err
}
