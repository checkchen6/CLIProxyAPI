package api

import (
	"path/filepath"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/logging"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/usagestats"
	coreusage "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/usage"
	log "github.com/sirupsen/logrus"
)

// initUsageStats initializes the usage statistics module:
// opens (or creates) the SQLite database, registers the usage plugin,
// and attaches management API routes to the given router group.
func (s *Server) initUsageStats(mgmt *gin.RouterGroup) {
	if s == nil || s.engine == nil {
		return
	}

	// Determine database path: place it inside the logs directory.
	dbDir := logging.ResolveLogDirectory(s.cfg)
	dbPath := filepath.Join(dbDir, "usage-stats.db")

	store, err := usagestats.NewStore(dbPath)
	if err != nil {
		log.WithError(err).Error("usagestats: failed to open database, module disabled")
		return
	}

	// Keep a reference so Server.Stop() can close the database cleanly.
	s.usageStatsStore = store

	// Register as a named usage plugin so it receives all usage records.
	plugin := usagestats.NewPlugin(store)
	coreusage.RegisterNamedPlugin("usagestats", plugin)

	// Attach management API routes to the existing management group.
	handler := usagestats.NewHandler(store)
	handler.RegisterRoutes(mgmt)

	log.Infof("usagestats: module initialized, database at %s", dbPath)
}
