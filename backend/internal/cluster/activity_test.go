package cluster

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"sync"
	"testing"

	"k8s.io/client-go/rest"
)

func TestAPIActivityTracksMonotonicTotals(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	activity.AddReceived(3)
	activity.AddSent(5)
	if snapshot := activity.Snapshot(); snapshot.BytesReceived != 3 || snapshot.BytesSent != 5 {
		t.Fatalf("Snapshot = %#v", snapshot)
	}
	activity.AddReceived(7)
	activity.AddReceived(11)
	activity.AddSent(13)
	if snapshot := activity.Snapshot(); snapshot.BytesReceived != 21 || snapshot.BytesSent != 18 {
		t.Fatalf("Snapshot after burst = %#v", snapshot)
	}
}

func TestAPIActivityTracksConnectionHealthAndRawError(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}

	assertHealth := func(statusCode int, roundTripErr error, want APIConnectionHealth) {
		t.Helper()
		activity.ObserveRoundTrip(nil, statusCode, roundTripErr)
		if got := activity.Snapshot().ConnectionHealth; got != want {
			t.Fatalf("connection health = %v, want %v", got, want)
		}
	}

	assertHealth(http.StatusOK, nil, APIConnectionConnected)
	// Forbidden is resource authorization, not a broken cluster connection.
	assertHealth(http.StatusForbidden, nil, APIConnectionConnected)
	assertHealth(0, errors.New("sensitive transport detail"), APIConnectionReconnecting)
	if got := activity.Snapshot().ConnectionError; got != "sensitive transport detail" {
		t.Fatalf("connection error = %q", got)
	}
	assertHealth(http.StatusUnauthorized, nil, APIConnectionAuthenticationFailed)
	assertHealth(http.StatusNoContent, nil, APIConnectionConnected)
}

func TestAPIActivityIgnoresConsumerCancellationForConnectionHealth(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	activity.ObserveRoundTrip(nil, 0, errors.New("proxyconnect tcp: EOF"))

	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(
		ctx, http.MethodGet, "https://cluster.test/api/v1/pods?watch=true", nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	activity.ObserveRoundTrip(request, 0, context.Canceled)

	snapshot := activity.Snapshot()
	if snapshot.ConnectionHealth != APIConnectionReconnecting ||
		snapshot.ConnectionError != "proxyconnect tcp: EOF" {
		t.Fatalf("consumer cancellation changed connection health = %#v", snapshot)
	}
}

func TestAPIActivityPublishesWarmCacheChangesWithoutPayloadActivity(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	authority := WarmCacheUsage{
		RetainedViews: 2, RetainedObjects: 300, RetainedBytes: 4096,
		ViewLimit: 8, ObjectLimit: 100_000, ByteLimit: 1 << 30,
		BudgetEvictions: 4,
	}
	global := WarmCacheUsage{
		RetainedViews: 5, RetainedObjects: 900, RetainedBytes: 16_384,
		ViewLimit: 24, ObjectLimit: 250_000, ByteLimit: 2 << 30,
		BudgetEvictions: 7,
	}
	activity.setWarmCacheUsage(1, authority, global)
	snapshot := activity.Snapshot()
	if snapshot.AuthorityWarmCache != authority || snapshot.GlobalWarmCache != global ||
		snapshot.BytesReceived != 0 || snapshot.BytesSent != 0 {
		t.Fatalf("warm-cache snapshot = %#v", snapshot)
	}

	activity.setWarmCacheUsage(2, authority, global)
	if installed := activity.warm.Load(); installed == nil || installed.generation != 2 {
		t.Fatalf("identical newer warm-cache generation was not installed: %#v", installed)
	}
}

func TestAPIActivityRejectsOutOfOrderWarmCachePublication(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	newerAuthority := WarmCacheUsage{RetainedViews: 2, BudgetEvictions: 3}
	newerGlobal := WarmCacheUsage{RetainedViews: 4, BudgetEvictions: 5}
	activity.setWarmCacheUsage(2, newerAuthority, newerGlobal)

	activity.setWarmCacheUsage(
		1,
		WarmCacheUsage{RetainedViews: 1, BudgetEvictions: 1},
		WarmCacheUsage{RetainedViews: 1, BudgetEvictions: 1},
	)
	if snapshot := activity.Snapshot(); snapshot.AuthorityWarmCache != newerAuthority || snapshot.GlobalWarmCache != newerGlobal {
		t.Fatalf("stale generation replaced warm-cache telemetry = %#v", snapshot)
	}
}

func TestActivityRoundTripperCountsOnlyBytesActuallyRead(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	base := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request == nil || request.Body == nil {
			t.Fatal("wrapped request body is missing")
		}
		buffer := make([]byte, 2)
		if count, err := request.Body.Read(buffer); count != 2 || err != nil {
			t.Fatalf("request read = %d, %v", count, err)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(bytes.NewBufferString("response")),
			Request:    request,
		}, nil
	})
	request, err := http.NewRequestWithContext(
		context.Background(), http.MethodPost, "https://cluster.test/api", bytes.NewBufferString("request"),
	)
	if err != nil {
		t.Fatal(err)
	}
	response, err := (&activityRoundTripper{base: base, activity: activity}).RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 3)
	if count, err := response.Body.Read(buffer); count != 3 || err != nil {
		t.Fatalf("response read = %d, %v", count, err)
	}
	_ = response.Body.Close()
	if snapshot := activity.Snapshot(); snapshot.BytesSent != 2 || snapshot.BytesReceived != 3 {
		t.Fatalf("Snapshot = %#v, want bytes actually read", snapshot)
	}
}

func TestActivityRoundTripperCountsRetriesWithoutMutatingOriginalRequest(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	base := roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if _, err := io.Copy(io.Discard, request.Body); err != nil {
			t.Fatal(err)
		}
		return nil, errors.New("retryable transport failure")
	})
	request, err := http.NewRequest(
		http.MethodPost, "https://cluster.test/api", bytes.NewBufferString("payload"),
	)
	if err != nil {
		t.Fatal(err)
	}
	originalBody := request.Body
	originalGetBody := request.GetBody
	wrapped := &activityRoundTripper{base: base, activity: activity}
	_, _ = wrapped.RoundTrip(request)
	if request.Body != originalBody || (request.GetBody == nil) != (originalGetBody == nil) {
		t.Fatal("RoundTrip mutated the caller's request")
	}
	retryBody, err := request.GetBody()
	if err != nil {
		t.Fatal(err)
	}
	retry := request.Clone(request.Context())
	retry.Body = retryBody
	_, _ = wrapped.RoundTrip(retry)
	if snapshot := activity.Snapshot(); snapshot.BytesSent != 14 || snapshot.BytesReceived != 0 {
		t.Fatalf("Snapshot after retry = %#v", snapshot)
	}
}

func TestActivityRoundTripperCountsConcurrentReads(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	const workers = 16
	var group sync.WaitGroup
	group.Add(workers)
	for range workers {
		go func() {
			defer group.Done()
			reader := &activityReadCloser{
				ReadCloser: io.NopCloser(bytes.NewReader(make([]byte, 1_024))),
				activity:   activity,
			}
			_, _ = io.Copy(io.Discard, reader)
		}()
	}
	group.Wait()
	if received := activity.Snapshot().BytesReceived; received != workers*1_024 {
		t.Fatalf("received = %d", received)
	}
}

func TestConfigWithAPIActivityPreservesExistingTransportWrapper(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	wrapped := false
	config := &rest.Config{WrapTransport: func(base http.RoundTripper) http.RoundTripper {
		wrapped = true
		return base
	}}
	derived := configWithAPIActivity(config, activity)
	if derived == config || config.WrapTransport == nil || derived.WrapTransport == nil {
		t.Fatal("activity config did not make an independent wrapped copy")
	}
	transport := derived.WrapTransport(roundTripFunc(func(request *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Body:       io.NopCloser(bytes.NewBufferString("body")),
			Request:    request,
		}, nil
	}))
	if !wrapped {
		t.Fatal("existing transport wrapper was not retained")
	}
	response, err := transport.RoundTrip(&http.Request{Method: http.MethodGet})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	if activity.Snapshot().BytesReceived != 4 {
		t.Fatal("derived client transport did not record response bytes")
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}
