package cluster

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"sync"
	"testing"
	"time"

	"k8s.io/client-go/rest"
)

func TestAPIActivityTracksMonotonicTotalsAndCoalescesHints(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	updates, unsubscribe := activity.Subscribe()
	unsubscribe()
	unsubscribe()
	activity.AddReceived(3)
	activity.AddSent(5)
	if snapshot := activity.Snapshot(); snapshot.BytesReceived != 3 || snapshot.BytesSent != 5 {
		t.Fatalf("Snapshot = %#v", snapshot)
	}

	updates, unsubscribe = activity.Subscribe()
	defer unsubscribe()
	activity.AddReceived(7)
	activity.AddReceived(11)
	activity.AddSent(13)
	select {
	case <-updates:
	case <-time.After(time.Second):
		t.Fatal("activity subscriber was not notified")
	}
	select {
	case <-updates:
		t.Fatal("activity hints were not coalesced")
	default:
	}
	if snapshot := activity.Snapshot(); snapshot.BytesReceived != 21 || snapshot.BytesSent != 18 {
		t.Fatalf("Snapshot after burst = %#v", snapshot)
	}
}

func TestAPIActivityTracksConnectionHealthWithoutRetainingErrors(t *testing.T) {
	t.Parallel()
	activity := &APIActivity{}
	updates, unsubscribe := activity.Subscribe()
	defer unsubscribe()

	assertHealth := func(statusCode int, roundTripErr error, want APIConnectionHealth) {
		t.Helper()
		activity.ObserveRoundTrip(statusCode, roundTripErr)
		select {
		case <-updates:
		case <-time.After(time.Second):
			t.Fatalf("no connection-health update for %d / %v", statusCode, roundTripErr)
		}
		if got := activity.Snapshot().ConnectionHealth; got != want {
			t.Fatalf("connection health = %v, want %v", got, want)
		}
	}

	assertHealth(http.StatusOK, nil, APIConnectionConnected)
	// Forbidden is resource authorization, not a broken cluster connection.
	activity.ObserveRoundTrip(http.StatusForbidden, nil)
	select {
	case <-updates:
		t.Fatal("unchanged connected state emitted a redundant hint")
	default:
	}
	assertHealth(0, errors.New("sensitive transport detail"), APIConnectionReconnecting)
	assertHealth(http.StatusUnauthorized, nil, APIConnectionAuthenticationFailed)
	assertHealth(http.StatusNoContent, nil, APIConnectionConnected)
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
