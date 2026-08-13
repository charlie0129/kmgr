package transport

import (
	"github.com/charlie0129/kmgr/backend/internal/object"
	"github.com/charlie0129/kmgr/backend/internal/view"
)

type relationshipCacheAdapter struct{ runtime *view.Runtime }

func (a relationshipCacheAdapter) CachedChildren(sessionID, ownerUID string) []object.CachedChild {
	if a.runtime == nil {
		return nil
	}
	values := a.runtime.CachedChildren(sessionID, ownerUID)
	result := make([]object.CachedChild, 0, len(values))
	for _, value := range values {
		result = append(result, object.CachedChild{
			Group: value.Group, Version: value.Version, Resource: value.Resource, Object: value.Object,
		})
	}
	return result
}
