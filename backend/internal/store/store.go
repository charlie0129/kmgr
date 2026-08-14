// Package store provides the UID-authoritative Kubernetes object cache.
package store

import (
	"cmp"
	"context"
	"errors"
	"slices"
	"strings"
	"sync"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

type NamespacedName struct {
	Namespace string
	Name      string
}

type Change struct {
	UID         types.UID
	ReplacedUID types.UID
	Created     bool
}

// SearchIdentity is the compact, immutable name index used by command-palette
// searches. Normalization happens once when an object enters the UID store,
// rather than once per query over every retained object.
type SearchIdentity struct {
	Object              *unstructured.Unstructured
	NormalizedName      string
	NormalizedQualified string
}

// UIDStore indexes immutable unstructured objects by Kubernetes UID. Objects
// supplied to Upsert must not be mutated after insertion.
type UIDStore struct {
	mu sync.RWMutex

	byUID                 map[types.UID]*unstructured.Unstructured
	byName                map[NamespacedName]types.UID
	byOwnerUID            map[types.UID]map[types.UID]struct{}
	byNodeName            map[string]map[types.UID]struct{}
	bySearchUID           map[types.UID]SearchIdentity
	byUIDBytes            map[types.UID]int64
	finiteBytes           int64
	unbounded             int
	finiteOverflow        bool
	indexHighWaterObjects int64
	indexHighWaterOwners  int64
	indexHighWaterNodes   int64
	ownerLinkHighWater    map[types.UID]int64
	nodeLinkHighWater     map[string]int64
	ownerLinkCapacity     int64
	nodeLinkCapacity      int64
	resourceVer           string
}

func New() *UIDStore {
	return &UIDStore{
		byUID:              make(map[types.UID]*unstructured.Unstructured),
		byName:             make(map[NamespacedName]types.UID),
		byOwnerUID:         make(map[types.UID]map[types.UID]struct{}),
		byNodeName:         make(map[string]map[types.UID]struct{}),
		bySearchUID:        make(map[types.UID]SearchIdentity),
		byUIDBytes:         make(map[types.UID]int64),
		ownerLinkHighWater: make(map[types.UID]int64),
		nodeLinkHighWater:  make(map[string]int64),
	}
}

func (s *UIDStore) Upsert(object *unstructured.Unstructured) Change {
	uid := object.GetUID()
	if uid == "" {
		panic("store: object has no UID")
	}
	key := NamespacedName{Namespace: object.GetNamespace(), Name: object.GetName()}
	objectBytes := estimateRetainedObjectBytes(object)

	s.mu.Lock()
	defer s.mu.Unlock()

	change := Change{UID: uid}
	if current, ok := s.byUID[uid]; ok {
		s.removeIndexesLocked(current)
		s.removeRetainedBytesLocked(uid)
	} else {
		change.Created = true
	}

	if previousUID, ok := s.byName[key]; ok && previousUID != uid {
		if previous := s.byUID[previousUID]; previous != nil {
			s.removeIndexesLocked(previous)
			s.removeRetainedBytesLocked(previousUID)
			delete(s.byUID, previousUID)
		}
		change.ReplacedUID = previousUID
	}

	s.byUID[uid] = object
	s.byName[key] = uid
	s.addRetainedBytesLocked(uid, objectBytes)
	s.addIndexesLocked(object)
	s.recordIndexHighWaterLocked()
	return change
}

func (s *UIDStore) Delete(uid types.UID) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	object, ok := s.byUID[uid]
	if !ok {
		return false
	}
	s.removeIndexesLocked(object)
	s.removeRetainedBytesLocked(uid)
	delete(s.byUID, uid)
	key := NamespacedName{Namespace: object.GetNamespace(), Name: object.GetName()}
	if s.byName[key] == uid {
		delete(s.byName, key)
	}
	return true
}

func (s *UIDStore) Get(uid types.UID) (*unstructured.Unstructured, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	object, ok := s.byUID[uid]
	return object, ok
}

func (s *UIDStore) GetByName(namespace, name string) (*unstructured.Unstructured, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	uid, ok := s.byName[NamespacedName{Namespace: namespace, Name: name}]
	if !ok {
		return nil, false
	}
	object, ok := s.byUID[uid]
	return object, ok
}

func (s *UIDStore) Children(ownerUID types.UID) []*unstructured.Unstructured {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.objectsForUIDSetLocked(s.byOwnerUID[ownerUID])
}

func (s *UIDStore) OnNode(nodeName string) []*unstructured.Unstructured {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.objectsForUIDSetLocked(s.byNodeName[nodeName])
}

func (s *UIDStore) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.byUID)
}

// RetainedBytes returns a conservative estimate of the heap retained by raw
// objects and the UID store's indexes. It is maintained incrementally so warm
// cache admission never needs to serialize or traverse a complete large view
// while holding a runtime lifecycle lock.
func (s *UIDStore) RetainedBytes() int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.unbounded != 0 || s.finiteOverflow {
		return maxRetainedBytes
	}
	return saturatingRetainedAdd(s.finiteBytes, s.retainedIndexHighWaterBytesLocked())
}

// Snapshot returns the immutable objects currently retained by the store in a
// deterministic namespace/name/UID order. The object pointers are not copied:
// callers must treat them as immutable, just as they do values returned by
// Get. Taking one slice snapshot avoids holding the store lock while a view
// performs filtering, CEL evaluation, or row projection.
func (s *UIDStore) Snapshot() []*unstructured.Unstructured {
	s.mu.RLock()
	defer s.mu.RUnlock()

	objects := make([]*unstructured.Unstructured, 0, len(s.byUID))
	for _, object := range s.byUID {
		objects = append(objects, object)
	}
	slices.SortFunc(objects, compareSnapshotObjects)
	return objects
}

// SnapshotContext is Snapshot with cancellation checks while both copying the
// UID map and establishing deterministic order. This keeps a retired large
// view from retaining a complete object-pointer slice merely because its
// catch-up was waiting in or executing snapshot work.
func (s *UIDStore) SnapshotContext(ctx context.Context) ([]*unstructured.Unstructured, error) {
	if ctx == nil {
		return nil, errors.New("store: snapshot context must not be nil")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	s.mu.RLock()
	objects := make([]*unstructured.Unstructured, 0, len(s.byUID))
	for _, object := range s.byUID {
		objects = append(objects, object)
		if len(objects)&255 == 0 {
			if err := ctx.Err(); err != nil {
				s.mu.RUnlock()
				return nil, err
			}
		}
	}
	s.mu.RUnlock()
	if err := sortSnapshotContext(ctx, objects); err != nil {
		return nil, err
	}
	return objects, nil
}

func sortSnapshotContext(ctx context.Context, objects []*unstructured.Unstructured) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(objects) < 2 {
		return nil
	}
	buffer := make([]*unstructured.Unstructured, len(objects))
	source, target := objects, buffer
	sourceIsObjects := true
	for width := 1; width < len(objects); {
		for left := 0; left < len(objects); left += 2 * width {
			if err := ctx.Err(); err != nil {
				return err
			}
			middle := min(left+width, len(objects))
			right := min(left+2*width, len(objects))
			first, second := left, middle
			for output := left; output < right; output++ {
				if output&255 == 0 {
					if err := ctx.Err(); err != nil {
						return err
					}
				}
				if second >= right || (first < middle && compareSnapshotObjects(source[first], source[second]) <= 0) {
					target[output] = source[first]
					first++
				} else {
					target[output] = source[second]
					second++
				}
			}
		}
		source, target = target, source
		sourceIsObjects = !sourceIsObjects
		if width > len(objects)/2 {
			width = len(objects)
		} else {
			width *= 2
		}
	}
	if !sourceIsObjects {
		for start := 0; start < len(objects); start += 256 {
			if err := ctx.Err(); err != nil {
				return err
			}
			copy(objects[start:min(start+256, len(objects))], source[start:min(start+256, len(objects))])
		}
	}
	return ctx.Err()
}

func compareSnapshotObjects(a, b *unstructured.Unstructured) int {
	if result := cmp.Compare(a.GetNamespace(), b.GetNamespace()); result != 0 {
		return result
	}
	if result := cmp.Compare(a.GetName(), b.GetName()); result != 0 {
		return result
	}
	return cmp.Compare(a.GetUID(), b.GetUID())
}

// SearchSnapshot returns the same deterministic identity order as Snapshot,
// plus normalized name keys maintained by Upsert. The retained object remains
// immutable and is not copied.
func (s *UIDStore) SearchSnapshot() []SearchIdentity {
	s.mu.RLock()
	defer s.mu.RUnlock()

	identities := make([]SearchIdentity, 0, len(s.bySearchUID))
	for _, identity := range s.bySearchUID {
		identities = append(identities, identity)
	}
	slices.SortFunc(identities, func(a, b SearchIdentity) int {
		if result := cmp.Compare(a.Object.GetNamespace(), b.Object.GetNamespace()); result != 0 {
			return result
		}
		if result := cmp.Compare(a.Object.GetName(), b.Object.GetName()); result != 0 {
			return result
		}
		return cmp.Compare(a.Object.GetUID(), b.Object.GetUID())
	})
	return identities
}

func (s *UIDStore) ResourceVersion() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.resourceVer
}

func (s *UIDStore) SetResourceVersion(resourceVersion string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.resourceVer = resourceVersion
}

// ReconcileSnapshot removes objects absent from a completed consistent LIST.
// Callers can Upsert progressive pages first and defer this method until the
// final page so cached objects never disappear from an incomplete relist.
func (s *UIDStore) ReconcileSnapshot(present map[types.UID]struct{}, resourceVersion string) []types.UID {
	s.mu.Lock()
	defer s.mu.Unlock()

	removed := make([]types.UID, 0)
	for uid, object := range s.byUID {
		if _, ok := present[uid]; ok {
			continue
		}
		s.removeIndexesLocked(object)
		s.removeRetainedBytesLocked(uid)
		delete(s.byUID, uid)
		key := NamespacedName{Namespace: object.GetNamespace(), Name: object.GetName()}
		if s.byName[key] == uid {
			delete(s.byName, key)
		}
		removed = append(removed, uid)
	}
	s.resourceVer = resourceVersion
	slices.Sort(removed)
	return removed
}

func (s *UIDStore) addIndexesLocked(object *unstructured.Unstructured) {
	uid := object.GetUID()
	name := strings.ToLower(object.GetName())
	s.bySearchUID[uid] = SearchIdentity{
		Object:              object,
		NormalizedName:      name,
		NormalizedQualified: strings.ToLower(object.GetNamespace()) + "/" + name,
	}
	for _, owner := range object.GetOwnerReferences() {
		if addToIndex(s.byOwnerUID, owner.UID, uid) {
			s.recordOwnerLinkHighWaterLocked(owner.UID)
		}
	}
	if nodeName, found, _ := unstructured.NestedString(object.Object, "spec", "nodeName"); found && nodeName != "" {
		if addToIndex(s.byNodeName, nodeName, uid) {
			s.recordNodeLinkHighWaterLocked(nodeName)
		}
	}
}

func (s *UIDStore) removeIndexesLocked(object *unstructured.Unstructured) {
	uid := object.GetUID()
	delete(s.bySearchUID, uid)
	for _, owner := range object.GetOwnerReferences() {
		if _, emptied := removeFromIndex(s.byOwnerUID, owner.UID, uid); emptied {
			s.ownerLinkCapacity -= s.ownerLinkHighWater[owner.UID]
			delete(s.ownerLinkHighWater, owner.UID)
		}
	}
	if nodeName, found, _ := unstructured.NestedString(object.Object, "spec", "nodeName"); found && nodeName != "" {
		if _, emptied := removeFromIndex(s.byNodeName, nodeName, uid); emptied {
			s.nodeLinkCapacity -= s.nodeLinkHighWater[nodeName]
			delete(s.nodeLinkHighWater, nodeName)
		}
	}
}

func (s *UIDStore) addRetainedBytesLocked(uid types.UID, objectBytes int64) {
	s.byUIDBytes[uid] = objectBytes
	if objectBytes == maxRetainedBytes {
		s.unbounded++
		return
	}
	if s.finiteOverflow || s.finiteBytes > maxRetainedBytes-objectBytes {
		s.finiteBytes = maxRetainedBytes
		s.finiteOverflow = true
		return
	}
	s.finiteBytes += objectBytes
}

func (s *UIDStore) removeRetainedBytesLocked(uid types.UID) {
	objectBytes, exists := s.byUIDBytes[uid]
	if !exists {
		return
	}
	delete(s.byUIDBytes, uid)
	if objectBytes == maxRetainedBytes {
		s.unbounded--
		return
	}
	if !s.finiteOverflow {
		s.finiteBytes -= objectBytes
		return
	}
	// Physical finite overflow is not realistic, but rebuilding from persisted
	// per-UID weights makes subtraction reversible without traversing payloads.
	s.finiteBytes = 0
	s.finiteOverflow = false
	for _, retained := range s.byUIDBytes {
		if retained == maxRetainedBytes {
			continue
		}
		if s.finiteBytes > maxRetainedBytes-retained {
			s.finiteBytes = maxRetainedBytes
			s.finiteOverflow = true
			break
		}
		s.finiteBytes += retained
	}
}

func (s *UIDStore) recordIndexHighWaterLocked() {
	s.indexHighWaterObjects = max(s.indexHighWaterObjects, int64(len(s.byUID)))
	s.indexHighWaterOwners = max(s.indexHighWaterOwners, int64(len(s.byOwnerUID)))
	s.indexHighWaterNodes = max(s.indexHighWaterNodes, int64(len(s.byNodeName)))
}

func (s *UIDStore) recordOwnerLinkHighWaterLocked(ownerUID types.UID) {
	current := int64(len(s.byOwnerUID[ownerUID]))
	if previous := s.ownerLinkHighWater[ownerUID]; current > previous {
		s.ownerLinkHighWater[ownerUID] = current
		s.ownerLinkCapacity += current - previous
	}
}

func (s *UIDStore) recordNodeLinkHighWaterLocked(nodeName string) {
	current := int64(len(s.byNodeName[nodeName]))
	if previous := s.nodeLinkHighWater[nodeName]; current > previous {
		s.nodeLinkHighWater[nodeName] = current
		s.nodeLinkCapacity += current - previous
	}
}

func (s *UIDStore) retainedIndexHighWaterBytesLocked() int64 {
	result := uidStoreBaseRetainedBytes
	result = saturatingRetainedAdd(result, saturatingRetainedMultiply(
		s.indexHighWaterObjects, topLevelIndexBytesPerObject,
	))
	result = saturatingRetainedAdd(result, saturatingRetainedMultiply(
		s.indexHighWaterOwners, topLevelIndexBytesPerOwner,
	))
	result = saturatingRetainedAdd(result, saturatingRetainedMultiply(
		s.indexHighWaterNodes, topLevelIndexBytesPerNode,
	))
	result = saturatingRetainedAdd(result, saturatingRetainedMultiply(
		s.ownerLinkCapacity, nestedIndexBytesPerLink,
	))
	return saturatingRetainedAdd(result, saturatingRetainedMultiply(
		s.nodeLinkCapacity, nestedIndexBytesPerLink,
	))
}

func (s *UIDStore) objectsForUIDSetLocked(set map[types.UID]struct{}) []*unstructured.Unstructured {
	objects := make([]*unstructured.Unstructured, 0, len(set))
	for uid := range set {
		if object := s.byUID[uid]; object != nil {
			objects = append(objects, object)
		}
	}
	slices.SortFunc(objects, func(a, b *unstructured.Unstructured) int {
		if result := cmp.Compare(a.GetNamespace(), b.GetNamespace()); result != 0 {
			return result
		}
		if result := cmp.Compare(a.GetName(), b.GetName()); result != 0 {
			return result
		}
		return cmp.Compare(a.GetUID(), b.GetUID())
	})
	return objects
}

func addToIndex[K comparable](index map[K]map[types.UID]struct{}, key K, uid types.UID) bool {
	values := index[key]
	if values == nil {
		values = make(map[types.UID]struct{})
		index[key] = values
	}
	if _, exists := values[uid]; exists {
		return false
	}
	values[uid] = struct{}{}
	return true
}

func removeFromIndex[K comparable](
	index map[K]map[types.UID]struct{}, key K, uid types.UID,
) (removed, emptied bool) {
	values := index[key]
	if _, exists := values[uid]; !exists {
		return false, false
	}
	delete(values, uid)
	if len(values) == 0 {
		delete(index, key)
		return true, true
	}
	return true, false
}
