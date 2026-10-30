package store

import (
	"database/sql"
	"errors"
	"time"

	"piggy-pal/server/internal/model"
)

// 单次运行最多认 12 小时，防止异常客户端把统计写爆。
const maxRunSec = 12 * 3600

// ===== 客户端设备 =====

// TouchClient 记录 / 刷新一台设备（client_id 由客户端首次启动生成）。
func (s *Store) TouchClient(clientID, label, platform, appVersion string) error {
	if clientID == "" {
		return nil
	}
	_, err := s.db.Exec(`
		INSERT INTO client_device (client_id, label, platform, app_version, last_seen, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(client_id) DO UPDATE SET
			label       = excluded.label,
			platform    = excluded.platform,
			app_version = excluded.app_version,
			last_seen   = excluded.last_seen`,
		clientID, label, platform, appVersion, now(), now())
	return err
}

// ListClients 最近活跃的设备列表（家长 / 运维排查用）。
func (s *Store) ListClients() ([]model.ClientDevice, error) {
	rows, err := s.db.Query(`
		SELECT client_id, COALESCE(label, ''), COALESCE(platform, ''),
		       COALESCE(app_version, ''), COALESCE(last_seen, ''), COALESCE(created_at, '')
		FROM client_device ORDER BY last_seen DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]model.ClientDevice, 0, 4)
	for rows.Next() {
		var d model.ClientDevice
		if err := rows.Scan(&d.ClientID, &d.Label, &d.Platform, &d.AppVersion, &d.LastSeen, &d.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	return out, rows.Err()
}

// ===== 运行时长（幂等） =====

// ReportRunDuration 记录某次运行（run_id）的累计时长，并把「增量」补进当天统计。
//
// 客户端每 30 秒上报一次累计值，网络重试、乱序、重复上报都只会按 max 补差，
// 因此不会多算；代价是进程被杀死时最多丢最后一个上报周期。
func (s *Store) ReportRunDuration(clientID, runID, childID, sessionID string, totalSec int) (int, error) {
	if runID == "" || childID == "" {
		return 0, nil
	}
	if totalSec < 0 {
		totalSec = 0
	}
	if totalSec > maxRunSec {
		totalSec = maxRunSec
	}

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	var prev int
	err = tx.QueryRow(`SELECT duration_sec FROM session_run WHERE run_id = ?`, runID).Scan(&prev)
	newRun := errors.Is(err, sql.ErrNoRows)
	if err != nil && !newRun {
		return 0, err
	}
	if newRun {
		prev = 0
	}
	if totalSec <= prev {
		// 重复 / 乱序上报，直接返回，避免重复累加
		return prev, tx.Commit()
	}

	date := dayOf(time.Now())
	if newRun {
		if _, err := tx.Exec(`
			INSERT INTO session_run (run_id, client_id, child_id, session_id, duration_sec, date, started_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
			runID, clientID, childID, sessionID, totalSec, date, now(), now()); err != nil {
			return 0, err
		}
	} else {
		if _, err := tx.Exec(`
			UPDATE session_run SET duration_sec = ?, updated_at = ? WHERE run_id = ?`,
			totalSec, now(), runID); err != nil {
			return 0, err
		}
	}

	// 新的一次运行 = 一次「打开」，只在首次上报时计 1
	openCount := 0
	if newRun {
		openCount = 1
	}
	if err := addCompanionRecordTx(tx, childID, 0, 0, totalSec-prev, openCount); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return totalSec, nil
}

// ===== 服务端指令 =====

// CreateCommand 给一台设备下发指令。
func (s *Store) CreateCommand(clientID, typ, params string) (*model.ClientCommand, error) {
	res, err := s.db.Exec(`
		INSERT INTO client_command (client_id, type, params, status, created_at)
		VALUES (?, ?, ?, 'pending', ?)`,
		clientID, typ, params, now())
	if err != nil {
		return nil, err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return nil, err
	}
	return s.getCommand(id)
}

// getCommand 按 id 读一条指令。
func (s *Store) getCommand(id int64) (*model.ClientCommand, error) {
	var c model.ClientCommand
	err := s.db.QueryRow(`
		SELECT id, client_id, type, COALESCE(params, ''), status,
		       COALESCE(created_at, ''), COALESCE(delivered_at, ''), COALESCE(acked_at, ''), COALESCE(result, '')
		FROM client_command WHERE id = ?`, id).
		Scan(&c.ID, &c.ClientID, &c.Type, &c.Params, &c.Status, &c.CreatedAt, &c.DeliveredAt, &c.AckedAt, &c.Result)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &c, nil
}

// TakeCommands 取走该设备待执行的指令，并标记为 delivered。
// 已经下发但 10 分钟没回执的（App 被杀死等）会再发一次，避免指令丢失。
func (s *Store) TakeCommands(clientID string, limit int) ([]model.ClientCommand, error) {
	if clientID == "" || limit <= 0 {
		return nil, nil
	}
	stale := time.Now().Add(-10 * time.Minute).Format(time.RFC3339)
	rows, err := s.db.Query(`
		SELECT id, client_id, type, COALESCE(params, ''), status,
		       COALESCE(created_at, ''), COALESCE(delivered_at, ''), COALESCE(acked_at, ''), COALESCE(result, '')
		FROM client_command
		WHERE client_id = ? AND (
			status = 'pending' OR
			(status = 'delivered' AND COALESCE(delivered_at, '') < ?)
		)
		ORDER BY id LIMIT ?`, clientID, stale, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]model.ClientCommand, 0, limit)
	for rows.Next() {
		var c model.ClientCommand
		if err := rows.Scan(&c.ID, &c.ClientID, &c.Type, &c.Params, &c.Status,
			&c.CreatedAt, &c.DeliveredAt, &c.AckedAt, &c.Result); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(out) == 0 {
		return out, nil
	}

	ts := now()
	for i := range out {
		if _, err := s.db.Exec(`UPDATE client_command SET status = 'delivered', delivered_at = ? WHERE id = ?`,
			ts, out[i].ID); err != nil {
			return out, err
		}
		out[i].Status = "delivered"
		out[i].DeliveredAt = ts
	}
	return out, nil
}

// AckCommand 客户端执行完指令后的回执。
func (s *Store) AckCommand(clientID string, id int64, ok bool, result string) error {
	status := "done"
	if !ok {
		status = "failed"
	}
	_, err := s.db.Exec(`
		UPDATE client_command SET status = ?, acked_at = ?, result = ?
		WHERE id = ? AND client_id = ?`, status, now(), result, id, clientID)
	return err
}

// ListCommands 查看某台设备最近的指令及执行结果。
func (s *Store) ListCommands(clientID string, limit int) ([]model.ClientCommand, error) {
	if limit <= 0 {
		limit = 20
	}
	rows, err := s.db.Query(`
		SELECT id, client_id, type, COALESCE(params, ''), status,
		       COALESCE(created_at, ''), COALESCE(delivered_at, ''), COALESCE(acked_at, ''), COALESCE(result, '')
		FROM client_command WHERE client_id = ? ORDER BY id DESC LIMIT ?`, clientID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]model.ClientCommand, 0, limit)
	for rows.Next() {
		var c model.ClientCommand
		if err := rows.Scan(&c.ID, &c.ClientID, &c.Type, &c.Params, &c.Status,
			&c.CreatedAt, &c.DeliveredAt, &c.AckedAt, &c.Result); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
