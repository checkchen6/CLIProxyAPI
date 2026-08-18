package usagestats

import (
	"context"
	"strings"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v7/internal/logging"
	coreusage "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/usage"
	log "github.com/sirupsen/logrus"
)

// Plugin implements coreusage.Plugin to capture usage records into the local store.
type Plugin struct {
	store *Store
}

// NewPlugin creates a usage stats plugin backed by the given store.
func NewPlugin(store *Store) *Plugin {
	return &Plugin{store: store}
}

// HandleUsage receives a completed usage record and persists it.
func (p *Plugin) HandleUsage(ctx context.Context, record coreusage.Record) {
	if p == nil || p.store == nil {
		return
	}

	endpoint := logging.GetEndpoint(ctx)
	category := classifyEndpoint(endpoint, record.Model)

	ts := record.RequestedAt
	if ts.IsZero() {
		ts = time.Now()
	}

	model := strings.TrimSpace(record.Model)
	if model == "" {
		model = "unknown"
	}

	alias := strings.TrimSpace(record.Alias)
	if alias == "" {
		alias = model
	}

	provider := strings.TrimSpace(record.Provider)
	if provider == "" {
		provider = "unknown"
	}

	row := UsageRow{
		Timestamp:    ts,
		Endpoint:     endpoint,
		Provider:     provider,
		Model:        model,
		Alias:        alias,
		Category:     category,
		InputTokens:  record.Detail.InputTokens,
		OutputTokens: record.Detail.OutputTokens,
		TotalTokens:  record.Detail.TotalTokens,
		Failed:       record.Failed,
		LatencyMs:    record.Latency.Milliseconds(),
		TTFTMs:       record.TTFT.Milliseconds(),
	}

	if err := p.store.Insert(row); err != nil {
		log.WithError(err).Warn("usagestats: failed to persist usage record")
	}
}

// classifyEndpoint determines the request category from the endpoint path and model name.
func classifyEndpoint(endpoint, model string) string {
	lower := strings.ToLower(endpoint)

	// Endpoint-based classification (most reliable)
	if strings.Contains(lower, "images/generations") || strings.Contains(lower, "images/edits") {
		return "image"
	}
	if strings.Contains(lower, "chat/completions") ||
		strings.Contains(lower, "/completions") ||
		strings.Contains(lower, "/responses") {
		return "chat"
	}

	// Model-name fallback for cases where endpoint is empty or ambiguous
	modelLower := strings.ToLower(model)
	if strings.Contains(modelLower, "image") || strings.Contains(modelLower, "imagine") ||
		strings.Contains(modelLower, "dall") {
		return "image"
	}

	if endpoint == "" {
		// If we have no endpoint info at all, fall back to chat for known chat models
		return "other"
	}

	return "other"
}
