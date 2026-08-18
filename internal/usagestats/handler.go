package usagestats

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
)

// Handler serves the usage statistics management API routes.
type Handler struct {
	store *Store
}

// NewHandler creates a handler backed by the given store.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

// RegisterRoutes registers usage stats routes on the given gin router group.
// The group should already have management auth middleware applied.
func (h *Handler) RegisterRoutes(group *gin.RouterGroup) {
	group.GET("/usage-stats/summary", h.GetSummary)
	group.GET("/usage-stats/hourly", h.GetHourly)
	group.GET("/usage-stats/models", h.GetModels)
	group.DELETE("/usage-stats/records", h.DeleteRecords)
}

// GetSummary returns aggregate counters for the requested time window.
func (h *Handler) GetSummary(c *gin.Context) {
	start, end := parseTimeRange(c)
	result, err := h.store.QuerySummary(start, end)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	c.JSON(http.StatusOK, result)
}

// GetHourly returns per-hour token and latency aggregates.
func (h *Handler) GetHourly(c *gin.Context) {
	start, end := parseTimeRange(c)
	rows, err := h.store.QueryHourly(start, end)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if rows == nil {
		rows = []HourlyRow{}
	}
	c.JSON(http.StatusOK, rows)
}

// GetModels returns per-model aggregate stats.
func (h *Handler) GetModels(c *gin.Context) {
	start, end := parseTimeRange(c)
	rows, err := h.store.QueryModels(start, end)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}
	if rows == nil {
		rows = []ModelRow{}
	}
	c.JSON(http.StatusOK, rows)
}

// DeleteRecords removes records older than the specified duration.
func (h *Handler) DeleteRecords(c *gin.Context) {
	beforeStr := c.Query("before")
	if beforeStr == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "missing 'before' parameter (RFC3339)"})
		return
	}
	before, err := time.Parse(time.RFC3339, beforeStr)
	if err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "invalid 'before' format, use RFC3339"})
		return
	}
	deleted, errDel := h.store.DeleteBefore(before)
	if errDel != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": errDel.Error()})
		return
	}
	c.JSON(http.StatusOK, gin.H{"deleted": deleted})
}

// parseTimeRange extracts start/end from query params, defaulting to today (UTC).
func parseTimeRange(c *gin.Context) (time.Time, time.Time) {
	now := time.Now().UTC()
	startOfDay := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)

	start := startOfDay
	end := now

	if s := c.Query("start"); s != "" {
		if parsed, err := time.Parse(time.RFC3339, s); err == nil {
			start = parsed
		}
	}
	if e := c.Query("end"); e != "" {
		if parsed, err := time.Parse(time.RFC3339, e); err == nil {
			end = parsed
		}
	}

	// Shortcut: range param
	switch c.Query("range") {
	case "today":
		start = startOfDay
		end = now
	case "7d":
		start = now.AddDate(0, 0, -7)
		end = now
	case "30d":
		start = now.AddDate(0, 0, -30)
		end = now
	}

	return start, end
}
