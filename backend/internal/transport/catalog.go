package transport

import (
	"path/filepath"
	"strings"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
)

// CatalogLoader loads a credential-bearing kubeconfig catalog. Callers must
// never log a Catalog or its errors without passing them through redaction.
type CatalogLoader func(paths []string) (*cluster.Catalog, error)

// CatalogRegistry retains immutable kubeconfig snapshots by ordered path set.
// A successful reload replaces only that path set; existing sessions continue
// to use the snapshot and credentials they were opened with.
type CatalogRegistry struct {
	mu      sync.RWMutex
	loader  CatalogLoader
	entries map[string]*cluster.Catalog
}

func NewCatalogRegistry(loader CatalogLoader) *CatalogRegistry {
	if loader == nil {
		loader = cluster.DiscoverPaths
	}
	return &CatalogRegistry{
		loader:  loader,
		entries: make(map[string]*cluster.Catalog),
	}
}

func (r *CatalogRegistry) Load(paths []string, reload bool) (*cluster.Catalog, error) {
	key := catalogKey(paths)
	if !reload {
		r.mu.RLock()
		catalog := r.entries[key]
		r.mu.RUnlock()
		if catalog != nil {
			return catalog, nil
		}
	}

	catalog, err := r.loader(append([]string(nil), paths...))
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	if !reload {
		if existing := r.entries[key]; existing != nil {
			r.mu.Unlock()
			return existing, nil
		}
	}
	r.entries[key] = catalog
	r.mu.Unlock()
	return catalog, nil
}

func catalogKey(paths []string) string {
	if len(paths) == 0 {
		return "\x00ambient"
	}
	var key strings.Builder
	key.WriteString("\x00explicit")
	for _, path := range paths {
		key.WriteByte(0)
		key.WriteString(filepath.Clean(path))
	}
	return key.String()
}
