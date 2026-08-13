// Package store provides the UID-authoritative Kubernetes object cache.
package store

import (
	"cmp"
	"slices"
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

// UIDStore indexes immutable unstructured objects by Kubernetes UID. Objects
// supplied to Upsert must not be mutated after insertion.
type UIDStore struct {
	mu sync.RWMutex

	byUID       map[types.UID]*unstructured.Unstructured
	byName      map[NamespacedName]types.UID
	byOwnerUID  map[types.UID]map[types.UID]struct{}
	byNodeName  map[string]map[types.UID]struct{}
	resourceVer string
}

func New() *UIDStore {
	return &UIDStore{
		byUID:      make(map[types.UID]*unstructured.Unstructured),
		byName:     make(map[NamespacedName]types.UID),
		byOwnerUID: make(map[types.UID]map[types.UID]struct{}),
		byNodeName: make(map[string]map[types.UID]struct{}),
	}
}

func (s *UIDStore) Upsert(object *unstructured.Unstructured) Change {
	uid := object.GetUID()
	if uid == "" {
		panic("store: object has no UID")
	}
	key := NamespacedName{Namespace: object.GetNamespace(), Name: object.GetName()}

	s.mu.Lock()
	defer s.mu.Unlock()

	change := Change{UID: uid}
	if current, ok := s.byUID[uid]; ok {
		s.removeIndexesLocked(current)
	} else {
		change.Created = true
	}

	if previousUID, ok := s.byName[key]; ok && previousUID != uid {
		if previous := s.byUID[previousUID]; previous != nil {
			s.removeIndexesLocked(previous)
			delete(s.byUID, previousUID)
		}
		change.ReplacedUID = previousUID
	}

	s.byUID[uid] = object
	s.byName[key] = uid
	s.addIndexesLocked(object)
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
	for _, owner := range object.GetOwnerReferences() {
		addToIndex(s.byOwnerUID, owner.UID, uid)
	}
	if nodeName, found, _ := unstructured.NestedString(object.Object, "spec", "nodeName"); found && nodeName != "" {
		addToIndex(s.byNodeName, nodeName, uid)
	}
}

func (s *UIDStore) removeIndexesLocked(object *unstructured.Unstructured) {
	uid := object.GetUID()
	for _, owner := range object.GetOwnerReferences() {
		removeFromIndex(s.byOwnerUID, owner.UID, uid)
	}
	if nodeName, found, _ := unstructured.NestedString(object.Object, "spec", "nodeName"); found && nodeName != "" {
		removeFromIndex(s.byNodeName, nodeName, uid)
	}
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

func addToIndex[K comparable](index map[K]map[types.UID]struct{}, key K, uid types.UID) {
	values := index[key]
	if values == nil {
		values = make(map[types.UID]struct{})
		index[key] = values
	}
	values[uid] = struct{}{}
}

func removeFromIndex[K comparable](index map[K]map[types.UID]struct{}, key K, uid types.UID) {
	values := index[key]
	delete(values, uid)
	if len(values) == 0 {
		delete(index, key)
	}
}
