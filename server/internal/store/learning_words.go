package store

import (
	"database/sql"
	"errors"
	"strings"
	"time"

	"piggy-pal/server/internal/model"
)

// reviewIntervalDays 掌握度 0→5 对应的下次复习间隔（天）。
// 0-1 天先巩固，之后逐步拉长，符合幼儿「多次短间隔」的记忆规律。
var reviewIntervalDays = []int{1, 2, 4, 7, 14, 30}

// RecordWordLearning 记录一轮对话里目标词的 heard / said，并安排下次复习日。
// heardWords / saidWords 都是本轮出现过的词（已去重），调用方负责先做匹配。
// 同一个词一轮内出现多次也只记一次，避免 AI 一段话反复说就把 heard_count 刷爆。
func (s *Store) RecordWordLearning(childID, date string, words []model.PlanWord, heardWords, saidWords []string) error {
	if childID == "" || len(words) == 0 {
		return nil
	}
	heard := make(map[string]bool, len(heardWords))
	for _, w := range heardWords {
		heard[strings.ToLower(w)] = true
	}
	said := make(map[string]bool, len(saidWords))
	for _, w := range saidWords {
		said[strings.ToLower(w)] = true
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	for _, w := range words {
		en := strings.ToLower(strings.TrimSpace(w.En))
		if en == "" {
			continue
		}
		h, sd := heard[en], said[en]
		if !h && !sd {
			continue
		}

		var (
			mastery    int
			heardCount int
			saidCount  int
			firstSeen  sql.NullString
		)
		err := tx.QueryRow(`
			SELECT COALESCE(mastery, 0), COALESCE(heard_count, 0),
			       COALESCE(said_count, 0), first_seen_date
			FROM word_learning WHERE child_id = ? AND word = ?`,
			childID, en).Scan(&mastery, &heardCount, &saidCount, &firstSeen)
		switch {
		case errors.Is(err, sql.ErrNoRows):
			// 第一次出现，按新词处理
		case err != nil:
			return err
		}

		if h {
			heardCount++
		}
		if sd {
			saidCount++
			if mastery < 5 {
				mastery++
			}
		}

		interval := reviewIntervalDays[mastery]
		next := date
		if t, err := time.Parse(dayLayout, date); err == nil {
			next = t.AddDate(0, 0, interval).Format(dayLayout)
		}
		first := firstSeen.String
		if first == "" {
			first = date
		}

		if _, err := tx.Exec(`
			INSERT INTO word_learning
				(child_id, word, zh, first_seen_date, last_seen_date,
				 heard_count, said_count, mastery, next_review_date, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(child_id, word) DO UPDATE SET
				zh = CASE WHEN excluded.zh <> '' THEN excluded.zh ELSE word_learning.zh END,
				last_seen_date = excluded.last_seen_date,
				heard_count = excluded.heard_count,
				said_count = excluded.said_count,
				mastery = excluded.mastery,
				next_review_date = excluded.next_review_date,
				updated_at = excluded.updated_at`,
			childID, en, strings.TrimSpace(w.Zh), first, date,
			heardCount, saidCount, mastery, next, now()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// DueReviewWords 返回今天到期该复习的词，最久没复习的优先。
func (s *Store) DueReviewWords(childID, today string, limit int) ([]model.WordLearning, error) {
	if limit <= 0 {
		limit = 3
	}
	rows, err := s.db.Query(`
		SELECT word, COALESCE(zh, ''), COALESCE(first_seen_date, ''),
		       COALESCE(last_seen_date, ''), COALESCE(heard_count, 0),
		       COALESCE(said_count, 0), COALESCE(mastery, 0),
		       COALESCE(next_review_date, '')
		FROM word_learning
		WHERE child_id = ? AND next_review_date <> '' AND next_review_date <= ?
		  AND mastery < 5
		ORDER BY next_review_date, mastery ASC
		LIMIT ?`, childID, today, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.WordLearning
	for rows.Next() {
		var w model.WordLearning
		w.ChildID = childID
		if err := rows.Scan(&w.Word, &w.Zh, &w.FirstSeenDate, &w.LastSeenDate,
			&w.HeardCount, &w.SaidCount, &w.Mastery, &w.NextReviewDate); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// WordLearningStats 返回今天待复习词数与已掌握词数，供星星页 / 家长报告展示。
func (s *Store) WordLearningStats(childID, today string) (toReview, mastered int, err error) {
	err = s.db.QueryRow(`
		SELECT
			COALESCE(SUM(CASE WHEN next_review_date <> '' AND next_review_date <= ? AND mastery < 5 THEN 1 ELSE 0 END), 0),
			COALESCE(SUM(CASE WHEN mastery >= 5 THEN 1 ELSE 0 END), 0)
		FROM word_learning WHERE child_id = ?`, today, childID).Scan(&toReview, &mastered)
	return
}

// TotalStars 累计星星（所有陪伴记录求和），用于贴纸解锁。
func (s *Store) TotalStars(childID string) (int, error) {
	var total int
	err := s.db.QueryRow(`SELECT COALESCE(SUM(stars), 0) FROM companion_record WHERE child_id = ?`,
		childID).Scan(&total)
	return total, err
}

// GetBedtimeStory 读取某天已生成的故事；found=false 表示今天还没生成过。
func (s *Store) GetBedtimeStory(childID, roleID, date string) (string, bool, error) {
	var content string
	err := s.db.QueryRow(`
		SELECT content FROM bedtime_story
		WHERE child_id = ? AND role_id = ? AND date = ?`,
		childID, roleID, date).Scan(&content)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return content, true, nil
}

// SaveBedtimeStory 保存当天故事（重复写入覆盖）。
func (s *Store) SaveBedtimeStory(childID, roleID, date, content string) error {
	_, err := s.db.Exec(`
		INSERT INTO bedtime_story (child_id, role_id, date, content, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(child_id, role_id, date) DO UPDATE SET
			content = excluded.content, created_at = excluded.created_at`,
		childID, roleID, date, content, now())
	return err
}
