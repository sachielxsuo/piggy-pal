package store

import (
	"context"
	"database/sql"
	_ "embed"
	"errors"
	"os"
	"path/filepath"
	"time"

	"piggy-pal/server/internal/model"

	_ "modernc.org/sqlite"
)

//go:embed schema.sql
var schemaSQL string

// Store 封装 SQLite 访问。规则/角色在 yaml 配置里，这里只存运行时数据。
type Store struct {
	db *sql.DB
}

// Open 打开（必要时创建）SQLite 数据库并执行建表迁移。
func Open(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, err
	}
	path := filepath.Join(dataDir, "app.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	// SQLite 单写：限制连接数避免 "database is locked"
	db.SetMaxOpenConns(1)
	// WAL：读不阻塞写、写不阻塞读，发布时新旧进程可以短暂共存（旧进程排空期间仍在写库），
	// sqlite3 CLI 的在线备份也不会和请求打架。
	// busy_timeout：拿不到写锁时等 5 秒而不是立刻报错，跨进程（含备份）也需要。
	for _, pragma := range []string{`PRAGMA journal_mode=WAL`, `PRAGMA busy_timeout=5000`} {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, err
		}
	}

	if _, err := db.Exec(schemaSQL); err != nil {
		db.Close()
		return nil, err
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

// Ping 探测数据库是否可用（readiness 用）。只读一次，不给健康检查增加写压力。
func (s *Store) Ping(ctx context.Context) error {
	var one int
	return s.db.QueryRowContext(ctx, `SELECT 1`).Scan(&one)
}

// migrate 处理老库的增量列变更（SQLite 的 CREATE TABLE IF NOT EXISTS 不会给已存在的表加列）。
func migrate(db *sql.DB) error {
	// v1.2 新增：child.en_name（英文名）
	var has int
	if err := db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('child') WHERE name = 'en_name'`).Scan(&has); err != nil {
		return err
	}
	if has == 0 {
		if _, err := db.Exec(`ALTER TABLE child ADD COLUMN en_name TEXT`); err != nil {
			return err
		}
	}
	return nil
}

// Close 关闭底层连接。
func (s *Store) Close() error { return s.db.Close() }

func now() string { return time.Now().Format(time.RFC3339) }

// ===== Child =====

// UpsertChild 创建或更新宝宝档案。
func (s *Store) UpsertChild(c *model.Child) error {
	if c.CreatedAt == "" {
		c.CreatedAt = now()
	}
	_, err := s.db.Exec(`
		INSERT INTO child (child_id, family_id, name, en_name, age, gender, preferences, avatar, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(child_id) DO UPDATE SET
			family_id=excluded.family_id, name=excluded.name, en_name=excluded.en_name, age=excluded.age,
			gender=excluded.gender, preferences=excluded.preferences, avatar=excluded.avatar`,
		c.ChildID, c.FamilyID, c.Name, c.EnName, c.Age, c.Gender, c.Preferences, c.Avatar, c.CreatedAt)
	return err
}

// GetChild 按 ID 读取宝宝档案。
func (s *Store) GetChild(id string) (*model.Child, error) {
	row := s.db.QueryRow(`SELECT child_id, family_id, name, en_name, age, gender, preferences, avatar, created_at FROM child WHERE child_id = ?`, id)
	c := &model.Child{}
	var age sql.NullInt64
	var enName, gender, preferences, avatar sql.NullString
	err := row.Scan(&c.ChildID, &c.FamilyID, &c.Name, &enName, &age, &gender, &preferences, &avatar, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	c.EnName = enName.String
	c.Age = int(age.Int64)
	c.Gender = gender.String
	c.Preferences = preferences.String
	c.Avatar = avatar.String
	return c, nil
}

// ListChildren 列出全部宝宝。
func (s *Store) ListChildren() ([]model.Child, error) {
	rows, err := s.db.Query(`SELECT child_id, family_id, name, en_name, age, gender, preferences, avatar, created_at FROM child ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := []model.Child{}
	for rows.Next() {
		c := model.Child{}
		var age sql.NullInt64
		var enName, gender, preferences, avatar sql.NullString
		if err := rows.Scan(&c.ChildID, &c.FamilyID, &c.Name, &enName, &age, &gender, &preferences, &avatar, &c.CreatedAt); err != nil {
			return nil, err
		}
		c.EnName = enName.String
		c.Age = int(age.Int64)
		c.Gender = gender.String
		c.Preferences = preferences.String
		c.Avatar = avatar.String
		out = append(out, c)
	}
	return out, rows.Err()
}

// ===== ChatMessage =====

// SaveMessage 写入一条对话记录。
func (s *Store) SaveMessage(m *model.ChatMessage) error {
	if m.CreatedAt == "" {
		m.CreatedAt = now()
	}
	res, err := s.db.Exec(`INSERT INTO chat_message (child_id, role_id, speaker, content, created_at) VALUES (?, ?, ?, ?, ?)`,
		m.ChildID, m.RoleID, m.Speaker, m.Content, m.CreatedAt)
	if err != nil {
		return err
	}
	m.ID, _ = res.LastInsertId()
	return nil
}

// GetMessage 按 ID 读取某宝宝的一条对话（重播历史语音时校验归属）。
func (s *Store) GetMessage(childID string, id int64) (*model.ChatMessage, error) {
	var m model.ChatMessage
	err := s.db.QueryRow(`
		SELECT id, child_id, role_id, speaker, content, created_at
		FROM chat_message WHERE id = ? AND child_id = ?`, id, childID).Scan(
		&m.ID, &m.ChildID, &m.RoleID, &m.Speaker, &m.Content, &m.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &m, nil
}

// RecentMessages 取某宝宝与某角色最近 limit 条对话（正序，供拼 LLM 上下文）。
func (s *Store) RecentMessages(childID, roleID string, limit int) ([]model.ChatMessage, error) {
	rows, err := s.db.Query(`
		SELECT id, child_id, role_id, speaker, content, created_at
		FROM chat_message WHERE child_id = ? AND role_id = ?
		ORDER BY id DESC LIMIT ?`, childID, roleID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.ChatMessage
	for rows.Next() {
		var m model.ChatMessage
		if err := rows.Scan(&m.ID, &m.ChildID, &m.RoleID, &m.Speaker, &m.Content, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// 反转为正序（最早在前）
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}
	return msgs, nil
}

// MessagesPage 取某宝宝与某角色的一页历史（正序）。
// beforeID > 0 时取比该条更早的一页（上滑加载更多）；返回是否还有更早的消息。
func (s *Store) MessagesPage(childID, roleID string, beforeID int64, limit int) ([]model.ChatMessage, bool, error) {
	if limit <= 0 {
		limit = 50
	}
	q := `SELECT id, child_id, role_id, speaker, content, created_at
		FROM chat_message WHERE child_id = ? AND role_id = ?`
	args := []any{childID, roleID}
	if beforeID > 0 {
		q += ` AND id < ?`
		args = append(args, beforeID)
	}
	// 多取一条用来判断是否还有更早的
	q += ` ORDER BY id DESC LIMIT ?`
	args = append(args, limit+1)

	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()

	msgs := make([]model.ChatMessage, 0, limit+1)
	for rows.Next() {
		var m model.ChatMessage
		if err := rows.Scan(&m.ID, &m.ChildID, &m.RoleID, &m.Speaker, &m.Content, &m.CreatedAt); err != nil {
			return nil, false, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, false, err
	}

	hasMore := len(msgs) > limit
	if hasMore {
		msgs = msgs[:limit]
	}
	// 反转为正序（最早在前）
	for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
		msgs[i], msgs[j] = msgs[j], msgs[i]
	}
	return msgs, hasMore, nil
}

// ===== DailyGreeting =====

// GetDailyGreeting 读取某宝宝某角色某天的开场话题。
func (s *Store) GetDailyGreeting(childID, roleID, date string) (string, bool, error) {
	var content string
	err := s.db.QueryRow(
		`SELECT content FROM daily_greeting WHERE child_id = ? AND role_id = ? AND date = ?`,
		childID, roleID, date).Scan(&content)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return content, true, nil
}

// SaveDailyGreeting 保存当天开场话题；同一天重复写入直接忽略（幂等）。
func (s *Store) SaveDailyGreeting(childID, roleID, date, content string) error {
	_, err := s.db.Exec(`
		INSERT INTO daily_greeting (child_id, role_id, date, content, created_at)
		VALUES (?, ?, ?, ?, ?)
		ON CONFLICT(child_id, role_id, date) DO NOTHING`,
		childID, roleID, date, content, now())
	return err
}

// RecentDailyGreetingTexts 取今天之前最近的 limit 条开场话题，用于让 LLM 每天换话题。
func (s *Store) RecentDailyGreetingTexts(childID, roleID, excludeDate string, limit int) ([]string, error) {
	rows, err := s.db.Query(`
		SELECT content FROM daily_greeting
		WHERE child_id = ? AND role_id = ? AND date < ?
		ORDER BY date DESC LIMIT ?`, childID, roleID, excludeDate, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var content string
		if err := rows.Scan(&content); err != nil {
			return nil, err
		}
		out = append(out, content)
	}
	return out, rows.Err()
}

// ===== Parent PIN =====

// GetPIN 读取某家庭的家长 PIN 哈希（无记录返回空串）。
func (s *Store) GetPIN(familyID string) (string, error) {
	var hash string
	err := s.db.QueryRow(`SELECT pin_hash FROM parent_pin WHERE family_id = ?`, familyID).Scan(&hash)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return hash, err
}

// SetPIN 设置/更新某家庭的家长 PIN 哈希。
func (s *Store) SetPIN(familyID, hash string) error {
	_, err := s.db.Exec(`
		INSERT INTO parent_pin (family_id, pin_hash) VALUES (?, ?)
		ON CONFLICT(family_id) DO UPDATE SET pin_hash=excluded.pin_hash`, familyID, hash)
	return err
}

// ===== Companion stats =====

// dayLayout 是 companion_record.date 的存储格式（服务器本地时区）。
const dayLayout = "2006-01-02"

func dayOf(t time.Time) string { return t.Format(dayLayout) }

// RecordActivity 累加某宝宝当天的陪伴统计。
// 每次对话成功累加 stars / word_count；会话结束时累加 duration_sec / open_count。
func (s *Store) RecordActivity(childID string, stars, words, durationSec, openCount int) error {
	if childID == "" {
		return nil
	}
	if stars == 0 && words == 0 && durationSec == 0 && openCount == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	if err := addCompanionRecordTx(tx, childID, stars, words, durationSec, openCount); err != nil {
		return err
	}
	return tx.Commit()
}

// addCompanionRecordTx 在事务内累加当天陪伴记录（同一宝宝同一天只有一条）。
func addCompanionRecordTx(tx *sql.Tx, childID string, stars, words, durationSec, openCount int) error {
	date := dayOf(time.Now())
	var id int64
	err := tx.QueryRow(`SELECT id FROM companion_record WHERE child_id = ? AND date = ? ORDER BY id LIMIT 1`, childID, date).Scan(&id)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		_, err = tx.Exec(`
			INSERT INTO companion_record (child_id, date, duration_sec, open_count, word_count, stars, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
			childID, date, durationSec, openCount, words, stars, now())
	case err != nil:
		return err
	default:
		_, err = tx.Exec(`
			UPDATE companion_record SET
				duration_sec = COALESCE(duration_sec, 0) + ?,
				open_count   = COALESCE(open_count, 0) + ?,
				word_count   = COALESCE(word_count, 0) + ?,
				stars        = COALESCE(stars, 0) + ?
			WHERE id = ?`, durationSec, openCount, words, stars, id)
	}
	return err
}

// RecordChatActivity 记录一轮对话：当天统计 + 本次会话星星，返回会话累计星星。
// 两者在同一事务里，避免一边成功一边失败。
func (s *Store) RecordChatActivity(childID, sessionID string, stars, words int) (int, error) {
	if childID == "" {
		return 0, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	if stars > 0 || words > 0 {
		if err := addCompanionRecordTx(tx, childID, stars, words, 0, 0); err != nil {
			return 0, err
		}
	}

	sessionStars := 0
	if sessionID != "" {
		if _, err := tx.Exec(`
			INSERT INTO companion_session (session_id, child_id, date, stars, duration_sec, updated_at)
			VALUES (?, ?, ?, ?, 0, ?)
			ON CONFLICT(session_id) DO UPDATE SET
				stars      = COALESCE(companion_session.stars, 0) + excluded.stars,
				updated_at = excluded.updated_at`,
			sessionID, childID, dayOf(time.Now()), stars, now()); err != nil {
			return 0, err
		}
		if err := tx.QueryRow(`SELECT COALESCE(stars, 0) FROM companion_session WHERE session_id = ?`, sessionID).Scan(&sessionStars); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return sessionStars, nil
}

// SyncSession 用客户端快照校准本次会话星星（绝对值，只增不减）。
// 每轮对话已经落过当天统计，这里只补客户端比服务端多出来的差额，
// 因此重复/延迟上报都不会重复加星。
func (s *Store) SyncSession(childID, sessionID string, stars int) (int, error) {
	if childID == "" || sessionID == "" || stars < 0 {
		return 0, nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	var cur int
	err = tx.QueryRow(`SELECT COALESCE(stars, 0) FROM companion_session WHERE session_id = ? AND child_id = ?`,
		sessionID, childID).Scan(&cur)
	if errors.Is(err, sql.ErrNoRows) {
		// 没有会话记录：只建档，不补当天统计（每轮对话已经记过，避免重复加星）
		if _, err := tx.Exec(`
			INSERT INTO companion_session (session_id, child_id, date, stars, duration_sec, updated_at)
			VALUES (?, ?, ?, ?, 0, ?)`,
			sessionID, childID, dayOf(time.Now()), stars, now()); err != nil {
			return 0, err
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		return stars, nil
	}
	if err != nil {
		return 0, err
	}

	if stars <= cur {
		return cur, tx.Commit()
	}
	delta := stars - cur
	if _, err := tx.Exec(`UPDATE companion_session SET stars = ?, updated_at = ? WHERE session_id = ?`,
		stars, now(), sessionID); err != nil {
		return 0, err
	}
	if err := addCompanionRecordTx(tx, childID, delta, 0, 0, 0); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return stars, nil
}

// GetSessionStars 读取某次会话的累计星星，没有记录时返回 0。
func (s *Store) GetSessionStars(childID, sessionID string) (int, error) {
	if childID == "" || sessionID == "" {
		return 0, nil
	}
	var stars int
	err := s.db.QueryRow(`SELECT COALESCE(stars, 0) FROM companion_session WHERE session_id = ? AND child_id = ?`,
		sessionID, childID).Scan(&stars)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	return stars, err
}

// GetChildStats 汇总宝宝今天 / 最近 7 天 / 累计的陪伴数据，并顺带刷新连续打卡天数。
func (s *Store) GetChildStats(childID string) (*model.ChildStats, error) {
	nowT := time.Now()
	today := dayOf(nowT)
	out := &model.ChildStats{
		ChildID: childID,
		Today:   model.DayStat{Date: today},
		Week:    make([]model.DayStat, 0, 7),
	}

	// 累计
	if err := s.db.QueryRow(`
		SELECT COALESCE(SUM(stars), 0), COALESCE(SUM(word_count), 0),
		       COALESCE(SUM(duration_sec), 0), COALESCE(SUM(open_count), 0)
		FROM companion_record WHERE child_id = ?`, childID).Scan(
		&out.Total.Stars, &out.Total.WordCount, &out.Total.DurationSec, &out.Total.OpenCount); err != nil {
		return nil, err
	}
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM chat_message WHERE child_id = ? AND speaker = 'child'`,
		childID).Scan(&out.Total.Utterances); err != nil {
		return nil, err
	}
	out.TotalUtterances = out.Total.Utterances

	// 最近 7 天（含今天，缺失日期补零）
	weekStart := nowT.AddDate(0, 0, -6)
	startDate := dayOf(weekStart)

	byDate := map[string]model.DayStat{}
	rows, err := s.db.Query(`
		SELECT date, COALESCE(SUM(stars), 0), COALESCE(SUM(word_count), 0),
		       COALESCE(SUM(duration_sec), 0), COALESCE(SUM(open_count), 0)
		FROM companion_record
		WHERE child_id = ? AND date >= ? AND date <= ?
		GROUP BY date`, childID, startDate, today)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var d model.DayStat
		if err := rows.Scan(&d.Date, &d.Stars, &d.WordCount, &d.DurationSec, &d.OpenCount); err != nil {
			rows.Close()
			return nil, err
		}
		byDate[d.Date] = d
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return nil, err
	}
	rows.Close()

	utterByDate := map[string]int{}
	uRows, err := s.db.Query(`
		SELECT substr(created_at, 1, 10) AS d, COUNT(*)
		FROM chat_message
		WHERE child_id = ? AND speaker = 'child' AND created_at >= ?
		GROUP BY d`, childID, startDate)
	if err != nil {
		return nil, err
	}
	for uRows.Next() {
		var d string
		var n int
		if err := uRows.Scan(&d, &n); err != nil {
			uRows.Close()
			return nil, err
		}
		utterByDate[d] = n
	}
	if err := uRows.Err(); err != nil {
		uRows.Close()
		return nil, err
	}
	uRows.Close()

	for i := 0; i < 7; i++ {
		d := dayOf(weekStart.AddDate(0, 0, i))
		stat := byDate[d]
		stat.Date = d
		stat.Utterances = utterByDate[d]
		if d == today {
			out.Today = stat
		}
		out.Week = append(out.Week, stat)
		out.WeekStars += stat.Stars
	}

	// 连续打卡：从今天（今天还没玩则从昨天）向前数连续有活动的天数
	activeDates := map[string]bool{}
	activeRows, err := s.db.Query(`
		SELECT DISTINCT date FROM companion_record
		WHERE child_id = ? AND (
			COALESCE(stars, 0) > 0 OR COALESCE(word_count, 0) > 0 OR COALESCE(duration_sec, 0) > 0
		)`, childID)
	if err != nil {
		return nil, err
	}
	for activeRows.Next() {
		var d string
		if err := activeRows.Scan(&d); err != nil {
			activeRows.Close()
			return nil, err
		}
		activeDates[d] = true
	}
	if err := activeRows.Err(); err != nil {
		activeRows.Close()
		return nil, err
	}
	activeRows.Close()

	cursor := nowT
	if !activeDates[today] {
		cursor = cursor.AddDate(0, 0, -1)
	}
	for activeDates[dayOf(cursor)] {
		out.StreakDays++
		cursor = cursor.AddDate(0, 0, -1)
	}

	_ = s.saveProgress(childID, out.StreakDays, activeDates, today)
	return out, nil
}

// saveProgress 把连续天数写回 child_progress，失败不影响统计返回。
func (s *Store) saveProgress(childID string, streak int, activeDates map[string]bool, today string) error {
	last := ""
	if activeDates[today] {
		last = time.Now().Format(time.RFC3339)
	}
	_, err := s.db.Exec(`
		INSERT INTO child_progress (child_id, learned_words, streak_days, last_session_at, updated_at)
		VALUES (?, '', ?, ?, ?)
		ON CONFLICT(child_id) DO UPDATE SET
			streak_days = excluded.streak_days,
			last_session_at = CASE WHEN excluded.last_session_at <> '' THEN excluded.last_session_at ELSE child_progress.last_session_at END,
			updated_at = excluded.updated_at`,
		childID, streak, last, now())
	return err
}
