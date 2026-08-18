package usagestats

import (
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

const (
	// flushBatchSize is the number of buffered rows that triggers an immediate flush.
	flushBatchSize = 64
	// flushInterval is the maximum time a record sits in the buffer before being written.
	flushInterval = 5 * time.Second
)

// Store provides persistent usage statistics storage backed by SQLite.
// Inserts are buffered and flushed in batches for better write throughput.
type Store struct {
	db   *sql.DB
	path string

	mu      sync.Mutex
	buffer  []UsageRow
	timer   *time.Timer
	closed  bool
	closeCh chan struct{}
}

// NewStore opens (or creates) the SQLite database at the given path.
func NewStore(dbPath string) (*Store, error) {
	// Ensure directory exists
	dir := filepath.Dir(dbPath)
	if dir != "" && dir != "." {
		if errMk := os.MkdirAll(dir, 0o755); errMk != nil {
			return nil, fmt.Errorf("usagestats: mkdir %s: %w", dir, errMk)
		}
	}

	db, err := sql.Open("sqlite", dbPath+"?_journal_mode=WAL&_busy_timeout=5000")
	if err != nil {
		return nil, fmt.Errorf("usagestats: open db: %w", err)
	}
	db.SetMaxOpenConns(1)

	s := &Store{
		db:      db,
		path:    dbPath,
		buffer:  make([]UsageRow, 0, flushBatchSize),
		closeCh: make(chan struct{}),
	}
	if errMigrate := s.migrate(); errMigrate != nil {
		_ = db.Close()
		return nil, fmt.Errorf("usagestats: migrate: %w", errMigrate)
	}
	return s, nil
}

// Close flushes any buffered records and closes the underlying database.
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	if s.timer != nil {
		s.timer.Stop()
		s.timer = nil
	}
	pending := s.buffer
	s.buffer = nil
	s.mu.Unlock()

	// Flush remaining buffered records.
	if len(pending) > 0 {
		_ = s.flushRows(pending)
	}
	return s.db.Close()
}

func (s *Store) migrate() error {
	const schema = `
CREATE TABLE IF NOT EXISTS usage_records (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	timestamp DATETIME NOT NULL,
	endpoint TEXT NOT NULL DEFAULT '',
	provider TEXT NOT NULL DEFAULT '',
	model TEXT NOT NULL DEFAULT '',
	alias TEXT NOT NULL DEFAULT '',
	category TEXT NOT NULL DEFAULT 'other',
	input_tokens INTEGER NOT NULL DEFAULT 0,
	output_tokens INTEGER NOT NULL DEFAULT 0,
	total_tokens INTEGER NOT NULL DEFAULT 0,
	failed INTEGER NOT NULL DEFAULT 0,
	latency_ms INTEGER NOT NULL DEFAULT 0,
	ttft_ms INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_usage_records_timestamp ON usage_records(timestamp);
CREATE INDEX IF NOT EXISTS idx_usage_records_category ON usage_records(category);
CREATE INDEX IF NOT EXISTS idx_usage_records_model ON usage_records(model);

CREATE TABLE IF NOT EXISTS usage_hourly (
	hour TEXT NOT NULL,
	category TEXT NOT NULL,
	model TEXT NOT NULL,
	provider TEXT NOT NULL,
	total_requests INTEGER NOT NULL DEFAULT 0,
	failed_requests INTEGER NOT NULL DEFAULT 0,
	sum_input_tokens INTEGER NOT NULL DEFAULT 0,
	sum_output_tokens INTEGER NOT NULL DEFAULT 0,
	sum_total_tokens INTEGER NOT NULL DEFAULT 0,
	sum_latency_ms INTEGER NOT NULL DEFAULT 0,
	sum_ttft_ms INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (hour, category, model, provider)
);
`
	_, err := s.db.Exec(schema)
	return err
}

// UsageRow represents a single usage record to be inserted.
type UsageRow struct {
	Timestamp    time.Time
	Endpoint     string
	Provider     string
	Model        string
	Alias        string
	Category     string
	InputTokens  int64
	OutputTokens int64
	TotalTokens  int64
	Failed       bool
	LatencyMs    int64
	TTFTMs       int64
}

// Insert buffers a usage record for batch writing.
// Records are flushed when the buffer is full or after flushInterval.
func (s *Store) Insert(row UsageRow) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return fmt.Errorf("usagestats: store is closed")
	}

	s.buffer = append(s.buffer, row)

	if len(s.buffer) >= flushBatchSize {
		// Buffer full — flush immediately.
		pending := s.buffer
		s.buffer = make([]UsageRow, 0, flushBatchSize)
		if s.timer != nil {
			s.timer.Stop()
			s.timer = nil
		}
		s.mu.Unlock()
		return s.flushRows(pending)
	}

	// Start a flush timer if not already running.
	if s.timer == nil {
		s.timer = time.AfterFunc(flushInterval, s.timerFlush)
	}
	s.mu.Unlock()
	return nil
}

// timerFlush is called by the flush timer to drain the buffer.
func (s *Store) timerFlush() {
	s.mu.Lock()
	if s.closed || len(s.buffer) == 0 {
		s.timer = nil
		s.mu.Unlock()
		return
	}
	pending := s.buffer
	s.buffer = make([]UsageRow, 0, flushBatchSize)
	s.timer = nil
	s.mu.Unlock()

	_ = s.flushRows(pending)
}

// flushRows writes a batch of rows to the database in a single transaction.
func (s *Store) flushRows(rows []UsageRow) error {
	if len(rows) == 0 {
		return nil
	}

	tx, err := s.db.Begin()
	if err != nil {
		return fmt.Errorf("usagestats: begin batch tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmtRecord, err := tx.Prepare(`INSERT INTO usage_records (timestamp, endpoint, provider, model, alias, category, input_tokens, output_tokens, total_tokens, failed, latency_ms, ttft_ms)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("usagestats: prepare record stmt: %w", err)
	}
	defer func() { _ = stmtRecord.Close() }()

	stmtHourly, err := tx.Prepare(`INSERT INTO usage_hourly (hour, category, model, provider, total_requests, failed_requests, sum_input_tokens, sum_output_tokens, sum_total_tokens, sum_latency_ms, sum_ttft_ms)
		VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(hour, category, model, provider) DO UPDATE SET
			total_requests = total_requests + 1,
			failed_requests = failed_requests + excluded.failed_requests,
			sum_input_tokens = sum_input_tokens + excluded.sum_input_tokens,
			sum_output_tokens = sum_output_tokens + excluded.sum_output_tokens,
			sum_total_tokens = sum_total_tokens + excluded.sum_total_tokens,
			sum_latency_ms = sum_latency_ms + excluded.sum_latency_ms,
			sum_ttft_ms = sum_ttft_ms + excluded.sum_ttft_ms`)
	if err != nil {
		return fmt.Errorf("usagestats: prepare hourly stmt: %w", err)
	}
	defer func() { _ = stmtHourly.Close() }()

	for i := range rows {
		row := &rows[i]
		failedInt := 0
		if row.Failed {
			failedInt = 1
		}

		if _, err = stmtRecord.Exec(
			row.Timestamp.UTC(), row.Endpoint, row.Provider, row.Model, row.Alias, row.Category,
			row.InputTokens, row.OutputTokens, row.TotalTokens, failedInt, row.LatencyMs, row.TTFTMs,
		); err != nil {
			return fmt.Errorf("usagestats: insert record: %w", err)
		}

		hour := row.Timestamp.UTC().Truncate(time.Hour).Format(time.RFC3339)
		if _, err = stmtHourly.Exec(
			hour, row.Category, row.Model, row.Provider,
			failedInt, row.InputTokens, row.OutputTokens, row.TotalTokens, row.LatencyMs, row.TTFTMs,
		); err != nil {
			return fmt.Errorf("usagestats: upsert hourly: %w", err)
		}
	}

	return tx.Commit()
}

// SummaryResult holds top-level aggregate counters.
type SummaryResult struct {
	TotalRequests  int64 `json:"total_requests"`
	FailedRequests int64 `json:"failed_requests"`
	ChatRequests   int64 `json:"chat_requests"`
	ImageRequests  int64 `json:"image_requests"`
	OtherRequests  int64 `json:"other_requests"`
	ChatTokens     int64 `json:"chat_tokens"`
	ChatInput      int64 `json:"chat_input"`
	ChatOutput     int64 `json:"chat_output"`
	ImageTokens    int64 `json:"image_tokens"`
}

// QuerySummary returns aggregate counters for the given time window.
func (s *Store) QuerySummary(start, end time.Time) (SummaryResult, error) {
	var r SummaryResult
	row := s.db.QueryRow(`SELECT
		COALESCE(SUM(total_requests), 0),
		COALESCE(SUM(failed_requests), 0),
		COALESCE(SUM(CASE WHEN category='chat' THEN total_requests ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='image' THEN total_requests ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='other' THEN total_requests ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='chat' THEN sum_total_tokens ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='chat' THEN sum_input_tokens ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='chat' THEN sum_output_tokens ELSE 0 END), 0),
		COALESCE(SUM(CASE WHEN category='image' THEN sum_total_tokens ELSE 0 END), 0)
	FROM usage_hourly WHERE hour >= ? AND hour < ?`,
		start.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339))

	err := row.Scan(&r.TotalRequests, &r.FailedRequests, &r.ChatRequests, &r.ImageRequests,
		&r.OtherRequests, &r.ChatTokens, &r.ChatInput, &r.ChatOutput, &r.ImageTokens)
	return r, err
}

// HourlyRow represents one hour of aggregated data.
type HourlyRow struct {
	Hour          string `json:"hour"`
	Category      string `json:"category"`
	TotalRequests int64  `json:"total_requests"`
	InputTokens   int64  `json:"input_tokens"`
	OutputTokens  int64  `json:"output_tokens"`
	TotalTokens   int64  `json:"total_tokens"`
	AvgLatencyMs  int64  `json:"avg_latency_ms"`
	AvgTTFTMs     int64  `json:"avg_ttft_ms"`
}

// QueryHourly returns per-hour aggregates for the given time window.
func (s *Store) QueryHourly(start, end time.Time) ([]HourlyRow, error) {
	rows, err := s.db.Query(`SELECT hour, category,
		SUM(total_requests), SUM(sum_input_tokens), SUM(sum_output_tokens), SUM(sum_total_tokens),
		CASE WHEN SUM(total_requests) > 0 THEN SUM(sum_latency_ms) / SUM(total_requests) ELSE 0 END,
		CASE WHEN SUM(total_requests) > 0 THEN SUM(sum_ttft_ms) / SUM(total_requests) ELSE 0 END
	FROM usage_hourly WHERE hour >= ? AND hour < ?
	GROUP BY hour, category ORDER BY hour`,
		start.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var result []HourlyRow
	for rows.Next() {
		var h HourlyRow
		if errScan := rows.Scan(&h.Hour, &h.Category, &h.TotalRequests, &h.InputTokens, &h.OutputTokens, &h.TotalTokens, &h.AvgLatencyMs, &h.AvgTTFTMs); errScan != nil {
			return nil, errScan
		}
		result = append(result, h)
	}
	return result, rows.Err()
}

// ModelRow represents per-model aggregate stats.
type ModelRow struct {
	Model        string `json:"model"`
	Category     string `json:"category"`
	Requests     int64  `json:"requests"`
	TotalTokens  int64  `json:"total_tokens"`
	AvgLatencyMs int64  `json:"avg_latency_ms"`
	AvgTTFTMs    int64  `json:"avg_ttft_ms"`
	Failed       int64  `json:"failed"`
}

// QueryModels returns per-model aggregates for the given time window.
func (s *Store) QueryModels(start, end time.Time) ([]ModelRow, error) {
	rows, err := s.db.Query(`SELECT model, category,
		SUM(total_requests), SUM(sum_total_tokens),
		CASE WHEN SUM(total_requests) > 0 THEN SUM(sum_latency_ms) / SUM(total_requests) ELSE 0 END,
		CASE WHEN SUM(total_requests) > 0 THEN SUM(sum_ttft_ms) / SUM(total_requests) ELSE 0 END,
		SUM(failed_requests)
	FROM usage_hourly WHERE hour >= ? AND hour < ?
	GROUP BY model, category ORDER BY SUM(total_requests) DESC`,
		start.UTC().Format(time.RFC3339), end.UTC().Format(time.RFC3339))
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()

	var result []ModelRow
	for rows.Next() {
		var m ModelRow
		if errScan := rows.Scan(&m.Model, &m.Category, &m.Requests, &m.TotalTokens, &m.AvgLatencyMs, &m.AvgTTFTMs, &m.Failed); errScan != nil {
			return nil, errScan
		}
		result = append(result, m)
	}
	return result, rows.Err()
}

// DeleteBefore removes records older than the given time.
func (s *Store) DeleteBefore(before time.Time) (int64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	ts := before.UTC().Format(time.RFC3339)

	tx, err := s.db.Begin()
	if err != nil {
		return 0, fmt.Errorf("usagestats: begin delete tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.Exec(`DELETE FROM usage_records WHERE timestamp < ?`, ts)
	if err != nil {
		return 0, err
	}
	if _, err = tx.Exec(`DELETE FROM usage_hourly WHERE hour < ?`, ts); err != nil {
		return 0, err
	}
	if err = tx.Commit(); err != nil {
		return 0, err
	}

	return res.RowsAffected()
}
