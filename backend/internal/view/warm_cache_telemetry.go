package view

// WarmCacheUsage is aggregate process-memory warm-cache accounting. It never
// contains an authority identity or an individual cache/query key.
type WarmCacheUsage struct {
	RetainedViews   uint64
	RetainedObjects uint64
	RetainedBytes   uint64
	ViewLimit       uint64
	ObjectLimit     uint64
	ByteLimit       uint64
	BudgetEvictions uint64
}

// WarmCacheTelemetry is one coherent process-wide snapshot. Authorities are
// keyed only by the runtime's opaque process-local identity so the transport
// layer can route each aggregate to its matching shared backend.
type WarmCacheTelemetry struct {
	Global          WarmCacheUsage
	AuthorityBudget WarmCacheUsage
	Authorities     map[string]WarmCacheUsage
}

// WarmCacheTelemetrySnapshot returns current retained weights, configured
// limits, and cumulative budget-driven evictions without exposing cache keys.
func (r *Runtime) WarmCacheTelemetrySnapshot() WarmCacheTelemetry {
	if r == nil {
		return WarmCacheTelemetry{}
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.warmCacheTelemetrySnapshotLocked()
}

// RetireWarmCacheAuthority discards telemetry and reusable entries tied to a
// backend whose Kubernetes clients have closed. Entries still draining an
// active pipeline are rejected by the authority-active admission check when
// they later become quiescent, so random backend-lifetime IDs cannot build an
// append-only telemetry history.
func (r *Runtime) RetireWarmCacheAuthority(authorityID string) {
	if r == nil || authorityID == "" {
		return
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	_, hadEvictions := r.warmBudgetEvictionsByAuthority[authorityID]
	delete(r.warmBudgetEvictionsByAuthority, authorityID)
	removedWarmEntry := false
	for key, entry := range r.resources {
		if key.authorityID != authorityID || entry == nil || entry.openers != 0 ||
			len(entry.subscribers) != 0 || entry.state != resourceIdle {
			continue
		}
		if entry.releaseTimer != nil {
			entry.releaseTimer.Stop()
			entry.releaseTimer = nil
		}
		removedWarmEntry = r.removeWarmLocked(key) || removedWarmEntry
		entry.warmProjection = nil
		delete(r.resources, key)
	}
	if cache := r.warmByAuthority[authorityID]; cache != nil && cache.Len() == 0 {
		delete(r.warmByAuthority, authorityID)
	}
	if hadEvictions && !removedWarmEntry {
		r.signalWarmCacheTelemetryLocked()
	}
	r.mu.Unlock()
}

func (r *Runtime) warmCacheTelemetrySnapshotLocked() WarmCacheTelemetry {
	global := WarmCacheUsage{
		ViewLimit:       uint64(r.warmViewLimit),
		ObjectLimit:     uint64(r.warmObjectLimit),
		ByteLimit:       uint64(r.warmByteLimit),
		BudgetEvictions: r.warmBudgetEvictions,
	}
	if r.warm != nil {
		global.RetainedViews = uint64(r.warm.Len())
		global.RetainedObjects = uint64(r.warm.ObjectCount())
		global.RetainedBytes = uint64(r.warm.ByteCount())
	}
	authorityBudget := WarmCacheUsage{
		ViewLimit:   uint64(r.warmViewLimitPerAuthority),
		ObjectLimit: uint64(r.warmObjectLimitPerAuthority),
		ByteLimit:   uint64(r.warmByteLimitPerAuthority),
	}
	authorities := make(
		map[string]WarmCacheUsage,
		len(r.warmByAuthority)+len(r.warmBudgetEvictionsByAuthority),
	)
	for authorityID, cache := range r.warmByAuthority {
		if authorityID == "" || cache == nil {
			continue
		}
		usage := authorityBudget
		usage.RetainedViews = uint64(cache.Len())
		usage.RetainedObjects = uint64(cache.ObjectCount())
		usage.RetainedBytes = uint64(cache.ByteCount())
		usage.BudgetEvictions = r.warmBudgetEvictionsByAuthority[authorityID]
		authorities[authorityID] = usage
	}
	for authorityID, evictions := range r.warmBudgetEvictionsByAuthority {
		if authorityID == "" {
			continue
		}
		if _, exists := authorities[authorityID]; exists {
			continue
		}
		usage := authorityBudget
		usage.BudgetEvictions = evictions
		authorities[authorityID] = usage
	}
	return WarmCacheTelemetry{
		Global:          global,
		AuthorityBudget: authorityBudget,
		Authorities:     authorities,
	}
}

func (r *Runtime) startWarmCacheTelemetry() {
	if r == nil || r.warmCacheObserver == nil {
		return
	}
	r.warmCacheTelemetryWake = make(chan struct{}, 1)
	r.warmCacheTelemetryStop = make(chan chan struct{})
	// Publish configured budgets before any session can open a connection
	// stream. No Runtime/cache mutex is held while invoking the observer.
	r.warmCacheObserver(r.WarmCacheTelemetrySnapshot())
	go r.runWarmCacheTelemetry()
}

func (r *Runtime) runWarmCacheTelemetry() {
	for {
		select {
		case <-r.warmCacheTelemetryWake:
			snapshot := r.WarmCacheTelemetrySnapshot()
			r.warmCacheObserver(snapshot)
		case done := <-r.warmCacheTelemetryStop:
			// Close clears the cache before requesting this final serialized
			// publication, so no stale callback can follow the zero snapshot.
			snapshot := r.WarmCacheTelemetrySnapshot()
			r.warmCacheObserver(snapshot)
			close(done)
			return
		}
	}
}

// signalWarmCacheTelemetryLocked is a non-blocking hint only. The publisher
// takes its coherent snapshot later and invokes the observer without r.mu.
func (r *Runtime) signalWarmCacheTelemetryLocked() {
	if r == nil || r.warmCacheTelemetryWake == nil {
		return
	}
	select {
	case r.warmCacheTelemetryWake <- struct{}{}:
	default:
	}
}

func (r *Runtime) stopWarmCacheTelemetry() {
	if r == nil || r.warmCacheTelemetryStop == nil {
		return
	}
	done := make(chan struct{})
	r.warmCacheTelemetryStop <- done
	<-done
}

func (r *Runtime) recordWarmBudgetEvictionsLocked(keys []resourceKey) {
	if len(keys) == 0 {
		return
	}
	seen := make(map[resourceKey]struct{}, len(keys))
	const maximum = ^uint64(0)
	for _, key := range keys {
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		if r.warmBudgetEvictions != maximum {
			r.warmBudgetEvictions++
		}
		if !r.warmCacheAuthorityIsActiveLocked(key.authorityID) {
			continue
		}
		current := r.warmBudgetEvictionsByAuthority[key.authorityID]
		if current != maximum {
			r.warmBudgetEvictionsByAuthority[key.authorityID] = current + 1
		}
	}
}
