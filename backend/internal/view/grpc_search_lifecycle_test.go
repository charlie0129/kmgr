package view

import (
	"context"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestSearchRegistrationUsesGenerationPrimaryOrdering(t *testing.T) {
	t.Parallel()
	service := &GRPCService{searches: make(map[searchStreamKey]*searchRegistration)}
	activeKey := searchStreamKey{
		sessionID: "session", searchID: "palette", generation: 2, revision: 1,
	}
	activeContext, activeCancel := context.WithCancel(context.Background())
	active, err := service.registerSearch(activeKey, activeCancel)
	if err != nil {
		t.Fatal(err)
	}

	// Query revisions restart at one for a new generation. A delayed request
	// from generation one must not supersede generation two merely because its
	// within-generation revision is numerically larger.
	_, err = service.registerSearch(searchStreamKey{
		sessionID: "session", searchID: "palette", generation: 1, revision: 99,
	}, func() {})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("crossed stale registration error = %v, want failed precondition", err)
	}
	select {
	case <-activeContext.Done():
		t.Fatal("crossed stale registration canceled the newer generation")
	default:
	}
	if service.searches[activeKey] != active {
		t.Fatal("crossed stale registration replaced the newer generation")
	}

	// Conversely, a newer generation may validly restart its revision counter.
	newKey := searchStreamKey{
		sessionID: "session", searchID: "palette", generation: 3, revision: 1,
	}
	newContext, newCancel := context.WithCancel(context.Background())
	newRegistration, err := service.registerSearch(newKey, newCancel)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-activeContext.Done():
	default:
		t.Fatal("new generation did not cancel its predecessor")
	}
	if len(service.searches) != 1 || service.searches[newKey] != newRegistration {
		t.Fatalf("registrations after replacement = %#v", service.searches)
	}
	service.unregisterSearch(newKey, newRegistration)
	newCancel()
	select {
	case <-newContext.Done():
	default:
		t.Fatal("test cleanup did not cancel replacement context")
	}
}

func TestSearchRegistrationRejectsDuplicatesAndCleanupRequiresExactOwner(t *testing.T) {
	t.Parallel()
	service := &GRPCService{searches: make(map[searchStreamKey]*searchRegistration)}
	key := searchStreamKey{
		sessionID: "session", searchID: "palette", generation: 4, revision: 7,
	}
	firstContext, firstCancel := context.WithCancel(context.Background())
	first, err := service.registerSearch(key, firstCancel)
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.registerSearch(key, func() {})
	if status.Code(err) != codes.AlreadyExists {
		t.Fatalf("duplicate registration error = %v, want already exists", err)
	}
	select {
	case <-firstContext.Done():
		t.Fatal("duplicate registration canceled the exact active owner")
	default:
	}

	// Model CancelSearch removing the first registration before its handler's
	// deferred cleanup runs, followed by a retry that reuses the exact cursor.
	service.searchMu.Lock()
	delete(service.searches, key)
	service.searchMu.Unlock()
	firstCancel()
	retryContext, retryCancel := context.WithCancel(context.Background())
	retry, err := service.registerSearch(key, retryCancel)
	if err != nil {
		t.Fatal(err)
	}
	service.unregisterSearch(key, first)
	if service.searches[key] != retry {
		t.Fatal("delayed cleanup from the old owner removed the exact-cursor retry")
	}
	select {
	case <-retryContext.Done():
		t.Fatal("delayed cleanup from the old owner canceled the retry")
	default:
	}
	service.unregisterSearch(key, retry)
	retryCancel()
}
