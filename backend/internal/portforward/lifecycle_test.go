package portforward

import (
	"context"
	"errors"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes/fake"
)

func TestDirectPodLifecycleRetriesThenRejectsSameNameReplacement(t *testing.T) {
	t.Parallel()
	client := fake.NewClientset(readyPod("pod", "old-uid", 8080))
	forwarder := &fakeForwarder{ports: []uint16{43123}}
	backoff := &recordingBackoff{}
	manager := lifecycleManager(t, client, forwarder, backoff)
	defer manager.Close()
	updates, unsubscribe := manager.Subscribe()
	defer unsubscribe()

	_, err := manager.Start(StartRequest{
		ID: "direct-pod", Target: podIdentity("pod", "old-uid"), RemotePort: 8080,
	})
	if err != nil {
		t.Fatal(err)
	}
	initial := forwardStatesUntil(t, updates, func(snapshot Snapshot) bool {
		return snapshot.State == StateListening
	})
	assertForwardStateAbsent(t, initial, StateReconnecting)

	replaceLifecyclePod(t, client, readyPod("pod", "new-uid", 8080))
	failRunningForward(t, forwarder, 0, errors.New("connection lost"))
	afterFailure := forwardStatesUntil(t, updates, func(snapshot Snapshot) bool {
		return snapshot.State == StateFailed
	})
	assertForwardStatePresent(t, afterFailure, StateReconnecting)
	failed := manager.List("session", true)[0]
	if !errors.Is(failed.LastError, ErrPodRecreated) {
		t.Fatalf("reconnect error = %v, want ErrPodRecreated", failed.LastError)
	}
	if got := coreActionCount(client, "get", "pods"); got != 2 {
		t.Fatalf("Pod GET calls after connection loss = %d, want retry verification", got)
	}
	if got := backoff.Calls(); got != 1 {
		t.Fatalf("backoff calls after direct-Pod failure = %d, want 1", got)
	}
	assertForwardedPodUIDs(t, forwarder, "old-uid")
}

func TestServiceLifecycleReconnectsToSameNameReplacement(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "api"},
			Ports: []corev1.ServicePort{{
				Port: 80, TargetPort: intstr.FromInt32(8080),
			}},
		},
	}
	client := fake.NewClientset(service, readyPod("pod", "old-uid", 8080))
	forwarder := &fakeForwarder{ports: []uint16{43210, 43210}}
	backoff := &recordingBackoff{}
	manager := lifecycleManager(t, client, forwarder, backoff)
	defer manager.Close()
	updates, unsubscribe := manager.Subscribe()
	defer unsubscribe()

	_, err := manager.Start(StartRequest{
		ID: "service", Target: serviceIdentity("api", "service-uid"), RemotePort: 80,
	})
	if err != nil {
		t.Fatal(err)
	}
	initial := forwardStatesUntil(t, updates, func(snapshot Snapshot) bool {
		return snapshot.State == StateListening && snapshot.ResolvedPod != nil &&
			snapshot.ResolvedPod.UID == "old-uid"
	})
	assertForwardStateAbsent(t, initial, StateReconnecting)

	replaceLifecyclePod(t, client, readyPod("pod", "new-uid", 8080))
	failRunningForward(t, forwarder, 0, errors.New("connection lost"))
	reconnected := forwardStatesUntil(t, updates, func(snapshot Snapshot) bool {
		return snapshot.State == StateListening && snapshot.ResolvedPod != nil &&
			snapshot.ResolvedPod.UID == "new-uid"
	})
	assertForwardStatePresent(t, reconnected, StateReconnecting)
	if got := coreActionCount(client, "get", "services"); got != 2 {
		t.Fatalf("Service GET calls = %d, want one per resolution", got)
	}
	if got := coreActionCount(client, "list", "pods"); got != 2 {
		t.Fatalf("Pod LIST calls = %d, want one per resolution", got)
	}
	if got := backoff.Calls(); got != 1 {
		t.Fatalf("backoff calls = %d, want 1", got)
	}
	assertForwardedPodUIDs(t, forwarder, "old-uid", "new-uid")
}

func lifecycleManager(
	t *testing.T,
	client *fake.Clientset,
	forwarder Forwarder,
	backoff Backoff,
) *Manager {
	t.Helper()
	manager, err := NewManager(Config{
		Sessions: staticSessionResolver{session: Session{
			ContextName: "context",
			Resolver:    ClientGoTargetResolver{Core: client.CoreV1()},
			Forwarder:   forwarder,
		}},
		Backoff: backoff,
	})
	if err != nil {
		t.Fatal(err)
	}
	return manager
}

func replaceLifecyclePod(t *testing.T, client *fake.Clientset, replacement *corev1.Pod) {
	t.Helper()
	pods := client.CoreV1().Pods(replacement.Namespace)
	if err := pods.Delete(context.Background(), replacement.Name, metav1.DeleteOptions{}); err != nil {
		t.Fatalf("delete old Pod: %v", err)
	}
	if _, err := pods.Create(context.Background(), replacement, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create replacement Pod: %v", err)
	}
}

func failRunningForward(t *testing.T, forwarder *fakeForwarder, index int, err error) {
	t.Helper()
	eventuallyForward(t, func() bool {
		forwarder.mu.Lock()
		defer forwarder.mu.Unlock()
		return len(forwarder.runnings) > index
	})
	forwarder.mu.Lock()
	running := forwarder.runnings[index]
	forwarder.mu.Unlock()
	select {
	case running.result <- err:
	case <-time.After(time.Second):
		t.Fatal("timed out failing running port-forward")
	}
}

func forwardStatesUntil(
	t *testing.T,
	updates <-chan Snapshot,
	done func(Snapshot) bool,
) []State {
	t.Helper()
	states := make([]State, 0, 4)
	timer := time.NewTimer(time.Second)
	defer timer.Stop()
	for {
		select {
		case update := <-updates:
			states = append(states, update.State)
			if done(update) {
				return states
			}
		case <-timer.C:
			t.Fatalf("timed out waiting for port-forward state; observed %v", states)
		}
	}
}

func assertForwardStateAbsent(t *testing.T, states []State, unwanted State) {
	t.Helper()
	for _, state := range states {
		if state == unwanted {
			t.Fatalf("port-forward states %v unexpectedly contain %q", states, unwanted)
		}
	}
}

func assertForwardStatePresent(t *testing.T, states []State, wanted State) {
	t.Helper()
	for _, state := range states {
		if state == wanted {
			return
		}
	}
	t.Fatalf("port-forward states %v do not contain %q", states, wanted)
}

func coreActionCount(client *fake.Clientset, verb, resource string) int {
	count := 0
	for _, action := range client.Actions() {
		if action.GetVerb() == verb && action.GetResource().Resource == resource {
			count++
		}
	}
	return count
}

func assertForwardedPodUIDs(t *testing.T, forwarder *fakeForwarder, want ...string) {
	t.Helper()
	forwarder.mu.Lock()
	defer forwarder.mu.Unlock()
	if len(forwarder.requests) != len(want) {
		t.Fatalf("forward requests = %#v, want %d", forwarder.requests, len(want))
	}
	for index, uid := range want {
		if got := string(forwarder.requests[index].Pod.UID); got != uid {
			t.Fatalf("forward request %d Pod UID = %q, want %q", index, got, uid)
		}
	}
}
