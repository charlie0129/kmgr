package view

import (
	"crypto/sha256"
	"encoding/json"
	"math"

	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"google.golang.org/protobuf/proto"
)

type projectionCacheKey [sha256.Size]byte

const (
	// Bump either value when the retained protobuf shape or native projection
	// semantics change in a way that can make an in-process candidate invalid.
	warmProjectionSchemaVersion = "kmgr.warm-projection/v1"
	projectionRuntimePolicy     = "kmgr.view-projection/v1"
)

// warmProjection is an immutable, compact presentation snapshot. It owns no
// Subscription lifecycle state, goroutine, timer, or channel. Rows are treated
// as immutable protobuf values throughout the view runtime.
type warmProjection struct {
	key           projectionCacheKey
	rows          []*kmgrv1.ResourceRow
	retainedBytes int64
}

type projectionCacheSignature struct {
	SchemaVersion                string
	CELEnvironmentVersion        string
	RuntimePolicy                string
	ClusterSessionID             string
	Resource                     ResourceType
	NamespaceScope               NamespaceScope
	ColumnIDs                    []string
	FilterExpression             string
	Sort                         []SortDescriptor
	RequestedColumnConfiguration string
	ResolvedColumnConfiguration  string
	CELDefinitions               map[string]viewcolumns.Definition
	ColumnExtractors             map[string]viewcolumns.Extractor
}

// captureWarmProjectionUnlocked is called while Subscription.mu is held and
// before Runtime.mu is acquired. It performs the O(rows) compact slice/weight
// work without blocking unrelated resource lifecycles. A WATCH tombstone may
// remain in order until delivery; nil rows are skipped while survivor order is
// preserved exactly.
func (s *Subscription) captureWarmProjectionUnlocked() *warmProjection {
	if s == nil || s.closed || s.resource == nil {
		return nil
	}
	rows := make([]*kmgrv1.ResourceRow, 0, len(s.rows))
	seen := make(map[string]struct{}, len(s.rows))
	for _, uid := range s.order {
		row := s.rows[uid]
		if row == nil {
			continue
		}
		if _, duplicate := seen[uid]; duplicate {
			return nil
		}
		seen[uid] = struct{}{}
		rows = append(rows, row)
	}
	if len(rows) != len(s.rows) {
		return nil
	}
	return &warmProjection{
		key:           s.projectionCacheKey,
		rows:          rows,
		retainedBytes: projectedRowsRetainedBytes(rows),
	}
}

func newProjectionCacheKey(spec ProjectionSpec) projectionCacheKey {
	definitions := make(map[string]viewcolumns.Definition, len(spec.CELPrograms))
	for id, program := range spec.CELPrograms {
		definitions[id] = program.Definition()
	}
	payload, err := json.Marshal(projectionCacheSignature{
		SchemaVersion:                warmProjectionSchemaVersion,
		CELEnvironmentVersion:        viewcolumns.EnvironmentVersion,
		RuntimePolicy:                projectionRuntimePolicy,
		ClusterSessionID:             spec.ClusterSessionID,
		Resource:                     spec.Resource,
		NamespaceScope:               spec.NamespaceScope,
		ColumnIDs:                    spec.ColumnIDs,
		FilterExpression:             spec.FilterExpression,
		Sort:                         spec.Sort,
		RequestedColumnConfiguration: spec.ColumnConfigurationVersion,
		ResolvedColumnConfiguration:  spec.ResolvedColumnConfigurationVersion,
		CELDefinitions:               definitions,
		ColumnExtractors:             spec.ColumnExtractors,
	})
	if err != nil {
		// Every signature field above is JSON-safe by construction. Panicking here
		// prevents an impossible encoding failure from aliasing unrelated views to
		// the zero cache key.
		panic("view: encode projection cache signature: " + err.Error())
	}
	return sha256.Sum256(payload)
}

func projectedRowsRetainedBytes(rows []*kmgrv1.ResourceRow) int64 {
	result := saturatingProjectionBytes(24, saturatingProjectionProduct(int64(cap(rows)), 8))
	for _, row := range rows {
		if row == nil {
			continue
		}
		encoded := int64(proto.Size(row))
		// proto.Size accounts for encoded payload bytes, but rows also retain a
		// ResourceRow, ResourceIdentity, the Cells backing array, and one Cell
		// object per entry. Tiny cells otherwise look nearly free despite having
		// most of their cost in Go/protobuf object overhead.
		result = saturatingProjectionBytes(result, 512)
		result = saturatingProjectionBytes(result, saturatingProjectionProduct(int64(cap(row.Cells)), 256))
		result = saturatingProjectionBytes(result, saturatingProjectionBytes(encoded, encoded))
	}
	return result
}

func saturatingProjectionBytes(left, right int64) int64 {
	if left < 0 || right < 0 || left > math.MaxInt64-right {
		return math.MaxInt64
	}
	return left + right
}

func saturatingProjectionProduct(left, right int64) int64 {
	if left < 0 || right < 0 || (left != 0 && right > math.MaxInt64/left) {
		return math.MaxInt64
	}
	return left * right
}
