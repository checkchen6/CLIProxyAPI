package managementasset

import (
	"bytes"
	"embed"
	"sync"
)

// embeddedPanel holds the management control panel asset built from web/management.
//
// IMPORTANT: this file is a compiled artifact, not source. It is NOT regenerated
// automatically by the Go build, and there is currently no CI check that verifies
// it matches the web/management source. After changing anything under
// web/management you MUST rebuild and refresh it, otherwise the panel baked into
// the binary will silently drift from the source:
//
//	cd web/management && bun run build
//	cp dist/index.html ../../internal/managementasset/embedded/management.html
//
//go:embed embedded/management.html
var embeddedPanel embed.FS

const embeddedPanelPath = "embedded/management.html"

// embeddedPanelData caches the compiled-in panel asset and whether it is usable,
// resolved once on first access. The asset is a multi-megabyte blob and
// EmbeddedPanel is called on every control panel request, so we avoid re-reading
// and re-scanning it each time.
var (
	embeddedPanelOnce  sync.Once
	embeddedPanelBytes []byte
	embeddedPanelOK    bool
)

func loadEmbeddedPanel() {
	data, err := embeddedPanel.ReadFile(embeddedPanelPath)
	if err != nil {
		return
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return
	}
	embeddedPanelBytes = data
	embeddedPanelOK = true
}

// EmbeddedPanel returns the compiled-in management control panel asset.
// The second return value reports whether a usable asset is present.
func EmbeddedPanel() ([]byte, bool) {
	embeddedPanelOnce.Do(loadEmbeddedPanel)
	return embeddedPanelBytes, embeddedPanelOK
}

// HasEmbeddedPanel reports whether the binary ships a usable control panel asset.
func HasEmbeddedPanel() bool {
	embeddedPanelOnce.Do(loadEmbeddedPanel)
	return embeddedPanelOK
}
