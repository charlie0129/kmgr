package store

import (
	"fmt"
	"math"
	"slices"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
)

func TestUpdatePreservesUIDAndRecreationReplacesIt(t *testing.T) {
	t.Parallel()
	s := New()

	first := object("uid-1", "default", "web", "node-a")
	change := s.Upsert(first)
	if !change.Created || change.ReplacedUID != "" {
		t.Fatalf("first change = %#v", change)
	}

	updated := object("uid-1", "default", "web", "node-b")
	change = s.Upsert(updated)
	if change.Created || change.ReplacedUID != "" {
		t.Fatalf("update change = %#v", change)
	}
	if got := s.OnNode("node-a"); len(got) != 0 {
		t.Fatalf("old node index contains %d objects", len(got))
	}

	recreated := object("uid-2", "default", "web", "node-b")
	change = s.Upsert(recreated)
	if !change.Created || change.ReplacedUID != "uid-1" {
		t.Fatalf("recreate change = %#v", change)
	}
	if _, ok := s.Get("uid-1"); ok {
		t.Fatal("old UID remained after same-name recreation")
	}
	if got, ok := s.GetByName("default", "web"); !ok || got.GetUID() != "uid-2" {
		t.Fatalf("name lookup = %v, %v", got, ok)
	}
}

func TestIndexesFollowUpdateAndDelete(t *testing.T) {
	t.Parallel()
	s := New()
	child := object("child", "ns", "pod", "node-a")
	child.SetOwnerReferences([]metav1.OwnerReference{{UID: "owner-a"}})
	s.Upsert(child)

	if got := s.Children("owner-a"); len(got) != 1 || got[0].GetUID() != "child" {
		t.Fatalf("children = %#v", got)
	}
	if got := s.OnNode("node-a"); len(got) != 1 {
		t.Fatalf("node index = %#v", got)
	}
	if !s.Delete("child") || s.Delete("child") {
		t.Fatal("Delete result did not reflect presence")
	}
	if len(s.Children("owner-a")) != 0 || len(s.OnNode("node-a")) != 0 {
		t.Fatal("secondary indexes survived deletion")
	}
}

func TestReconcileDefersRemovalUntilCompletion(t *testing.T) {
	t.Parallel()
	s := New()
	s.Upsert(object("keep", "ns", "keep", ""))
	s.Upsert(object("remove", "ns", "remove", ""))

	// A progressive relist upsert does not remove warm cached rows.
	s.Upsert(object("keep", "ns", "keep", ""))
	if s.Len() != 2 {
		t.Fatalf("progressive page removed cached object, len = %d", s.Len())
	}

	removed := s.ReconcileSnapshot(map[types.UID]struct{}{"keep": {}}, "rv-2")
	if len(removed) != 1 || removed[0] != "remove" {
		t.Fatalf("removed = %v", removed)
	}
	if got := s.ResourceVersion(); got != "rv-2" {
		t.Fatalf("resource version = %q", got)
	}
}

func TestUpsertPanicsWithoutUID(t *testing.T) {
	t.Parallel()
	defer func() {
		if recover() == nil {
			t.Fatal("Upsert did not reject an object without UID")
		}
	}()
	New().Upsert(object("", "ns", "missing", ""))
}

func TestSnapshotUsesStableIdentityOrder(t *testing.T) {
	t.Parallel()
	s := New()
	for _, value := range []*unstructured.Unstructured{
		object("uid-c", "z", "same", ""),
		object("uid-b", "a", "same", ""),
		object("uid-a", "a", "first", ""),
	} {
		s.Upsert(value)
	}

	snapshot := s.Snapshot()
	got := make([]types.UID, 0, len(snapshot))
	for _, value := range snapshot {
		got = append(got, value.GetUID())
	}
	want := []types.UID{"uid-a", "uid-b", "uid-c"}
	if !slices.Equal(got, want) {
		t.Fatalf("Snapshot UIDs = %v, want %v", got, want)
	}
}

func TestSearchIndexNormalizesOnceAndFollowsUIDLifecycle(t *testing.T) {
	t.Parallel()
	s := New()
	s.Upsert(object("uid-old", "Team-A", "API-Server", ""))
	entries := s.SearchSnapshot()
	if len(entries) != 1 || entries[0].NormalizedName != "api-server" ||
		entries[0].NormalizedQualified != "team-a/api-server" ||
		entries[0].Object.GetUID() != "uid-old" {
		t.Fatalf("initial search index = %#v", entries)
	}

	// A same-name recreation replaces every index by UID.
	s.Upsert(object("uid-new", "Team-A", "API-Server", ""))
	entries = s.SearchSnapshot()
	if len(entries) != 1 || entries[0].Object.GetUID() != "uid-new" {
		t.Fatalf("recreated search index = %#v", entries)
	}
	if !s.Delete("uid-new") || len(s.SearchSnapshot()) != 0 {
		t.Fatal("deleted object remained in search index")
	}
}

func TestSearchIndexReconcilesCompletedSnapshot(t *testing.T) {
	t.Parallel()
	s := New()
	s.Upsert(object("keep", "ns", "Keep", ""))
	s.Upsert(object("remove", "ns", "Remove", ""))
	s.ReconcileSnapshot(map[types.UID]struct{}{"keep": {}}, "rv-2")
	entries := s.SearchSnapshot()
	if len(entries) != 1 || entries[0].Object.GetUID() != "keep" {
		t.Fatalf("reconciled search index = %#v", entries)
	}
}

func TestRetainedBytesFollowUpdateRecreationDeleteAndReconcile(t *testing.T) {
	t.Parallel()
	s := New()
	baseline := s.RetainedBytes()

	large := object("uid-large", "ns", "config", "")
	large.Object["data"] = map[string]any{"payload": string(make([]byte, 32<<10))}
	s.Upsert(large)
	largeBytes := s.RetainedBytes()
	if largeBytes <= baseline+(32<<10) {
		t.Fatalf("large object estimate = %d, baseline = %d", largeBytes, baseline)
	}

	small := object("uid-large", "ns", "config", "")
	s.Upsert(small)
	smallBytes := s.RetainedBytes()
	if smallBytes <= baseline || smallBytes >= largeBytes {
		t.Fatalf("updated estimate = %d, want between baseline %d and large %d", smallBytes, baseline, largeBytes)
	}

	recreated := object("uid-new", "ns", "config", "")
	s.Upsert(recreated)
	recreatedBytes := s.RetainedBytes()
	if recreatedBytes <= baseline || recreatedBytes >= smallBytes*2 {
		t.Fatalf("same-name recreation retained stale payload bytes: got %d, prior %d", recreatedBytes, smallBytes)
	}

	second := object("uid-second", "ns", "second", "")
	s.Upsert(second)
	twoObjectsBytes := s.RetainedBytes()
	if twoObjectsBytes <= smallBytes {
		t.Fatal("second object did not increase retained-byte estimate")
	}
	s.ReconcileSnapshot(map[types.UID]struct{}{"uid-new": {}}, "rv")
	wantReconciled := recreatedBytes + topLevelIndexBytesPerObject
	if got := s.RetainedBytes(); got != wantReconciled {
		t.Fatalf("reconciled estimate = %d, want %d", got, wantReconciled)
	}
	wantEmpty := baseline + 2*topLevelIndexBytesPerObject
	if !s.Delete("uid-new") || s.RetainedBytes() != wantEmpty {
		t.Fatalf("delete did not retain index high-water %d: got %d", wantEmpty, s.RetainedBytes())
	}
}

func TestRetainedBytesRecoverAfterUnsupportedObjectSaturatesEstimate(t *testing.T) {
	t.Parallel()
	s := New()
	finite := object("uid-finite", "ns", "finite", "")
	s.Upsert(finite)
	finiteBytes := s.RetainedBytes()
	finiteObjectBytes := s.finiteBytes
	invalid := object("uid-invalid", "ns", "invalid", "")
	invalid.Object["unsupported"] = struct{ Value string }{Value: "not unstructured JSON"}
	s.Upsert(invalid)
	if got := s.RetainedBytes(); got != math.MaxInt64 {
		t.Fatalf("unsupported graph estimate = %d, want saturation", got)
	}
	wantRetained := finiteBytes + topLevelIndexBytesPerObject
	if !s.Delete("uid-invalid") || s.RetainedBytes() != wantRetained || s.finiteBytes != finiteObjectBytes {
		t.Fatalf(
			"saturated estimate did not recover finite object/index bytes: retained=%d want=%d finite=%d want=%d",
			s.RetainedBytes(), wantRetained, s.finiteBytes, finiteObjectBytes,
		)
	}
}

func TestRetainedBytesKeepTopLevelIndexHighWaterAfterDeletes(t *testing.T) {
	t.Parallel()
	s := New()
	const count = 100
	for index := range count {
		s.Upsert(object(fmt.Sprintf("uid-%d", index), "ns", fmt.Sprintf("name-%d", index), ""))
	}
	for index := range count {
		if !s.Delete(types.UID(fmt.Sprintf("uid-%d", index))) {
			t.Fatalf("delete %d failed", index)
		}
	}
	want := uidStoreBaseRetainedBytes + count*topLevelIndexBytesPerObject
	if got := s.RetainedBytes(); got != want {
		t.Fatalf("empty high-water estimate = %d, want %d", got, want)
	}
}

func TestRetainedBytesUsePersistedWeightAfterAccidentalMutation(t *testing.T) {
	t.Parallel()
	s := New()
	value := object("uid", "ns", "name", "")
	s.Upsert(value)
	value.Object["accidental"] = string(make([]byte, 1<<20))
	if !s.Delete("uid") {
		t.Fatal("delete failed")
	}
	want := uidStoreBaseRetainedBytes + topLevelIndexBytesPerObject
	if got := s.RetainedBytes(); got != want || s.finiteBytes != 0 {
		t.Fatalf("mutated delete estimate = %d/finite %d, want %d/0", got, s.finiteBytes, want)
	}
}

func TestRetainedBytesKeepNestedOwnerMembershipHighWaterAfterReconcile(t *testing.T) {
	t.Parallel()
	s := New()
	const objectCount = 40
	const ownerCount = 25
	owners := make([]metav1.OwnerReference, ownerCount)
	for index := range owners {
		owners[index] = metav1.OwnerReference{UID: types.UID(fmt.Sprintf("owner-%d", index))}
	}
	for index := range objectCount {
		value := object(fmt.Sprintf("uid-%d", index), "ns", fmt.Sprintf("name-%d", index), "")
		value.SetOwnerReferences(owners)
		s.Upsert(value)
	}
	if got, want := s.ownerLinkCapacity, int64(objectCount*ownerCount); got != want {
		t.Fatalf("owner-link high-water = %d, want %d", got, want)
	}

	s.ReconcileSnapshot(map[types.UID]struct{}{"uid-0": {}}, "rv")
	currentLinks := int64(0)
	for _, children := range s.byOwnerUID {
		currentLinks += int64(len(children))
	}
	if currentLinks != ownerCount {
		t.Fatalf("current owner links = %d, want %d", currentLinks, ownerCount)
	}
	minimum := uidStoreBaseRetainedBytes + int64(objectCount*ownerCount)*nestedIndexBytesPerLink
	if got := s.RetainedBytes(); got < minimum {
		t.Fatalf("reconciled retained bytes = %d, want at least owner-link high-water %d", got, minimum)
	}
}

func TestRetainedBytesSumSequentialSurvivingOwnerMapHighWater(t *testing.T) {
	t.Parallel()
	s := New()
	const peak = 80
	ownerA := metav1.OwnerReference{UID: "owner-a"}
	ownerB := metav1.OwnerReference{UID: "owner-b"}
	for index := range peak {
		value := object(fmt.Sprintf("a-%d", index), "ns", fmt.Sprintf("a-%d", index), "")
		value.SetOwnerReferences([]metav1.OwnerReference{ownerA})
		s.Upsert(value)
	}
	s.ReconcileSnapshot(map[types.UID]struct{}{"a-0": {}}, "rv-a")
	for index := range peak {
		value := object(fmt.Sprintf("b-%d", index), "ns", fmt.Sprintf("b-%d", index), "")
		value.SetOwnerReferences([]metav1.OwnerReference{ownerB})
		s.Upsert(value)
	}
	s.ReconcileSnapshot(map[types.UID]struct{}{"a-0": {}, "b-0": {}}, "rv-b")

	wantCapacity := int64(2 * peak)
	if s.ownerLinkCapacity != wantCapacity {
		t.Fatalf("sequential owner-map capacity = %d, want %d", s.ownerLinkCapacity, wantCapacity)
	}
	if s.ownerLinkHighWater[ownerA.UID] != peak || s.ownerLinkHighWater[ownerB.UID] != peak {
		t.Fatalf("per-owner high-water = %#v", s.ownerLinkHighWater)
	}
	minimum := uidStoreBaseRetainedBytes + wantCapacity*nestedIndexBytesPerLink
	if got := s.RetainedBytes(); got < minimum {
		t.Fatalf("sequential retained bytes = %d, want at least %d", got, minimum)
	}
}

func object(uid, namespace, name, node string) *unstructured.Unstructured {
	value := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "v1",
		"kind":       "Pod",
		"metadata": map[string]any{
			"uid":       uid,
			"namespace": namespace,
			"name":      name,
		},
	}}
	if node != "" {
		value.Object["spec"] = map[string]any{"nodeName": node}
	}
	return value
}
