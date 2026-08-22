package transport

import (
	"path/filepath"
	"strings"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
)

// CatalogLoader loads a credential-bearing kubeconfig catalog plus isolated
// outcomes for each user-added file. Callers must never log a discovery or its
// errors without passing them through redaction.
type CatalogLoader func(paths []string) (*cluster.KubeconfigDiscovery, error)

// CatalogRegistry retains immutable kubeconfig discoveries by ordered added
// path set. A successful reload replaces only that path set; existing sessions
// continue to use the snapshot and credentials they were opened with.
type CatalogRegistry struct {
	mu      sync.RWMutex
	loader  CatalogLoader
	entries map[string]*cluster.KubeconfigDiscovery
}

func NewCatalogRegistry(loader CatalogLoader) *CatalogRegistry {
	if loader == nil {
		loader = cluster.DiscoverWithAddedPaths
	}
	return &CatalogRegistry{
		loader:  loader,
		entries: make(map[string]*cluster.KubeconfigDiscovery),
	}
}

func (r *CatalogRegistry) Load(
	paths []string,
	reload bool,
) (*cluster.KubeconfigDiscovery, error) {
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
		return "\x00ambient-only"
	}
	var key strings.Builder
	key.WriteString("\x00added")
	for _, path := range paths {
		key.WriteByte(0)
		key.WriteString(filepath.Clean(path))
	}
	return key.String()
}
