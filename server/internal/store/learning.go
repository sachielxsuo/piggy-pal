package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"piggy-pal/server/internal/model"
)

// SaveLearningPlan 原子写入一周计划（7 天）。重复写入同一天会覆盖，便于重生成。
func (s *Store) SaveLearningPlan(childID, weekStart, source string, days []model.PlanDay) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.Exec(`
		INSERT INTO learning_plan (child_id, week_start, source, created_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(child_id, week_start) DO UPDATE SET
			source = excluded.source, created_at = excluded.created_at`,
		childID, weekStart, source, now()); err != nil {
		return err
	}
	for _, d := range days {
		raw, err := json.Marshal(d.Words)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`
			INSERT INTO learning_plan_day (child_id, date, week_start, day_index, theme, words, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(child_id, date) DO UPDATE SET
				week_start = excluded.week_start, day_index = excluded.day_index,
				theme = excluded.theme, words = excluded.words, created_at = excluded.created_at`,
			childID, d.Date, weekStart, d.DayIndex, d.Theme, string(raw), now()); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// GetLearningPlanWeek 读取某个宝宝某一周的计划（按 day_index 排序）。
// found=false 表示这一周还没生成过。
func (s *Store) GetLearningPlanWeek(childID, weekStart string) (string, []model.PlanDay, bool, error) {
	var source sql.NullString
	err := s.db.QueryRow(`SELECT source FROM learning_plan WHERE child_id = ? AND week_start = ?`,
		childID, weekStart).Scan(&source)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil, false, nil
	}
	if err != nil {
		return "", nil, false, err
	}

	rows, err := s.db.Query(`
		SELECT date, day_index, theme, words FROM learning_plan_day
		WHERE child_id = ? AND week_start = ?
		ORDER BY day_index`, childID, weekStart)
	if err != nil {
		return "", nil, false, err
	}
	defer rows.Close()

	days := make([]model.PlanDay, 0, 7)
	for rows.Next() {
		var d model.PlanDay
		var theme sql.NullString
		var raw string
		if err := rows.Scan(&d.Date, &d.DayIndex, &theme, &raw); err != nil {
			return "", nil, false, err
		}
		d.Theme = theme.String
		if err := json.Unmarshal([]byte(raw), &d.Words); err != nil {
			return "", nil, false, fmt.Errorf("计划词 JSON 解析失败: %w", err)
		}
		days = append(days, d)
	}
	if err := rows.Err(); err != nil {
		return "", nil, false, err
	}
	return source.String, days, true, nil
}

// GetLearningPlanDays 读取日期区间内已经生成过的计划日（含首尾）。
// 用于统计「近 7 天」：没生成过计划的日期不会出现在结果里。
func (s *Store) GetLearningPlanDays(childID, startDate, endDate string) ([]model.PlanDay, error) {
	rows, err := s.db.Query(`
		SELECT date, day_index, theme, words FROM learning_plan_day
		WHERE child_id = ? AND date >= ? AND date <= ?
		ORDER BY date`, childID, startDate, endDate)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	days := make([]model.PlanDay, 0, 7)
	for rows.Next() {
		var d model.PlanDay
		var theme sql.NullString
		var raw string
		if err := rows.Scan(&d.Date, &d.DayIndex, &theme, &raw); err != nil {
			return nil, err
		}
		d.Theme = theme.String
		if err := json.Unmarshal([]byte(raw), &d.Words); err != nil {
			return nil, fmt.Errorf("计划词 JSON 解析失败: %w", err)
		}
		days = append(days, d)
	}
	return days, rows.Err()
}

// MessagesBetween 读取日期区间内某个宝宝的对话（含首尾），按时间正序。
// 只取统计需要的字段，避免把整段历史都读进内存。
func (s *Store) MessagesBetween(childID, startDate, endDate string) ([]model.DatedMessage, error) {
	rows, err := s.db.Query(`
		SELECT substr(created_at, 1, 10), speaker, content FROM chat_message
		WHERE child_id = ? AND substr(created_at, 1, 10) >= ? AND substr(created_at, 1, 10) <= ?
		ORDER BY created_at, id`, childID, startDate, endDate)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []model.DatedMessage
	for rows.Next() {
		var m model.DatedMessage
		var content sql.NullString
		if err := rows.Scan(&m.Date, &m.Speaker, &content); err != nil {
			return nil, err
		}
		m.Content = content.String
		out = append(out, m)
	}
	return out, rows.Err()
}

// PreviousWeekWords 读取上一周计划里的全部单词，供本周计划避开重复。
func (s *Store) PreviousWeekWords(childID, weekStart string) ([]string, error) {
	rows, err := s.db.Query(`
		SELECT words FROM learning_plan_day
		WHERE child_id = ? AND week_start < ?
		ORDER BY date DESC LIMIT 7`, childID, weekStart)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var words []model.PlanWord
		if err := json.Unmarshal([]byte(raw), &words); err != nil {
			continue
		}
		for _, w := range words {
			out = append(out, w.En)
		}
	}
	return out, rows.Err()
}
