package execstream

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/podidentity"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/util/flowcontrol"
)

type executorFunc func(context.Context, remotecommand.StreamOptions) error

func (f executorFunc) Stream(options remotecommand.StreamOptions) error {
	return f(context.Background(), options)
}

func (f executorFunc) StreamWithContext(ctx context.Context, options remotecommand.StreamOptions) error {
	return f(ctx, options)
}

func TestClientGoRunnerVerifiesPodAndBuildsExecRequest(t *testing.T) {
	t.Parallel()

	type observedRequest struct {
		method        string
		path          string
		authorization string
	}
	requests := make(chan observedRequest, 1)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		requests <- observedRequest{
			method: request.Method, path: request.URL.Path,
			authorization: request.Header.Get("Authorization"),
		}
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"pod-uid"}}`)
	}))
	defer server.Close()

	limiter := flowcontrol.NewTokenBucketRateLimiter(12.5, 37)
	config := &rest.Config{
		Host: server.URL, BearerToken: "test-bearer-token", RateLimiter: limiter,
	}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	var execURL string
	var factoryConfig *rest.Config
	stdout := new(bytes.Buffer)
	stderr := new(bytes.Buffer)
	stdin := bytes.NewBufferString("input")
	resize := newResizeQueue(nil)
	started := false
	executed := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(receivedConfig *rest.Config, requestURL string, ready func()) (remotecommand.Executor, error) {
			factoryConfig = receivedConfig
			execURL = requestURL
			return executorFunc(func(ctx context.Context, options remotecommand.StreamOptions) error {
				executed = true
				if started {
					t.Error("runner reported Running before the executor established its transport")
				}
				ready()
				if ctx == nil || options.Stdin != stdin || options.Stdout != stdout || options.Stderr != stderr ||
					options.Tty || options.TerminalSizeQueue != resize {
					t.Errorf("stream options were not forwarded: %#v", options)
				}
				return nil
			}), nil
		}),
	}
	request := testStart(1)
	request.TTY = false
	request.InitialSize = nil
	request.Command = []string{"/bin/sh", "-lc", "printf hello"}
	err = runner.Run(context.Background(), request, RunOptions{
		Stdin: stdin, Stdout: stdout, Stderr: stderr, Resizes: resize,
		Started: func() { started = true },
	})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !started || !executed {
		t.Fatalf("started = %t, executed = %t", started, executed)
	}
	if factoryConfig == config || factoryConfig.Host != config.Host || factoryConfig.BearerToken != config.BearerToken {
		t.Fatalf("executor config was not a faithful copy: %#v", factoryConfig)
	}
	if factoryConfig.RateLimiter != limiter {
		t.Fatal("exec transport copy replaced the authority-wide limiter")
	}

	parsed, err := url.Parse(execURL)
	if err != nil {
		t.Fatalf("parse exec URL: %v", err)
	}
	if parsed.Path != "/api/v1/namespaces/default/pods/api-0/exec" {
		t.Fatalf("exec path = %q", parsed.Path)
	}
	wantQuery := url.Values{
		"command":   {"/bin/sh", "-lc", "printf hello"},
		"container": {"main"},
		"stderr":    {"true"},
		"stdin":     {"true"},
		"stdout":    {"true"},
	}
	if got := parsed.Query(); !reflect.DeepEqual(got, wantQuery) {
		t.Fatalf("exec query = %#v, want %#v", got, wantQuery)
	}
	select {
	case observed := <-requests:
		if observed.method != http.MethodGet || observed.path != "/api/v1/namespaces/default/pods/api-0" ||
			observed.authorization != "Bearer test-bearer-token" {
			t.Fatalf("Pod verification request = %#v", observed)
		}
	default:
		t.Fatal("Pod verification request was not observed")
	}
}

func TestClientGoRunnerRejectsRecreatedPodBeforeExec(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"replacement-uid"}}`)
	}))
	defer server.Close()
	config := &rest.Config{Host: server.URL}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	factoryCalled := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(*rest.Config, string, func()) (remotecommand.Executor, error) {
			factoryCalled = true
			return nil, errors.New("must not construct an executor")
		}),
	}
	err = runner.Run(context.Background(), testStart(1), RunOptions{})
	var mismatch *UIDMismatchError
	if !errors.As(err, &mismatch) || mismatch.Expected != "pod-uid" || mismatch.Actual != "replacement-uid" {
		t.Fatalf("UID mismatch error = %#v", err)
	}
	if factoryCalled {
		t.Fatal("executor factory was called for a recreated Pod")
	}
}

func TestClientGoRunnerDoesNotReportRunningWhenTransportUpgradeFails(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(writer, `{"apiVersion":"meta.k8s.io/v1","kind":"PartialObjectMetadata","metadata":{"namespace":"default","name":"api-0","uid":"pod-uid"}}`)
	}))
	defer server.Close()
	config := &rest.Config{Host: server.URL}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	metadataClient, err := metadata.NewForConfig(config)
	if err != nil {
		t.Fatalf("metadata NewForConfig: %v", err)
	}
	upgradeErr := errors.New("upgrade rejected")
	started := false
	runner := ClientGoRunner{
		Core: core, PodUIDs: podidentity.MetadataGetter{Client: metadataClient}, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(*rest.Config, string, func()) (remotecommand.Executor, error) {
			return executorFunc(func(context.Context, remotecommand.StreamOptions) error {
				return upgradeErr
			}), nil
		}),
	}
	err = runner.Run(context.Background(), testStart(1), RunOptions{Started: func() { started = true }})
	if !errors.Is(err, upgradeErr) {
		t.Fatalf("Run error = %v, want %v", err, upgradeErr)
	}
	if started {
		t.Fatal("transport upgrade failure was reported as Running")
	}
}

func TestClientGoRunnerCreatesAttachesAndDeletesNodeShellHelper(t *testing.T) {
	t.Parallel()
	fixture := newNodeShellAPIFixture(t)
	defer fixture.close()
	core, config := fixture.client(t)

	var attachURL string
	started := false
	runner := ClientGoRunner{
		Core: core, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(
			_ *rest.Config, requestURL string, ready func(),
		) (remotecommand.Executor, error) {
			attachURL = requestURL
			return executorFunc(func(_ context.Context, options remotecommand.StreamOptions) error {
				ready()
				started = true
				if !options.Tty || options.Stdin == nil || options.Stdout == nil ||
					options.Stderr != nil {
					t.Errorf("node-shell stream options = %#v", options)
				}
				return nil
			}), nil
		}),
	}
	request := testNodeShellStart()
	err := runner.Run(context.Background(), request, RunOptions{
		Stdin: bytes.NewBuffer(nil), Stdout: new(bytes.Buffer), TTY: true,
	})
	if err != nil {
		t.Fatalf("Run node shell: %v", err)
	}
	if !started {
		t.Fatal("node-shell attach did not start")
	}
	parsed, err := url.Parse(attachURL)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Path != "/api/v1/namespaces/ops/pods/helper-1/attach" ||
		parsed.Query().Get("container") != nodeShellContainerName ||
		parsed.Query().Get("stdin") != "true" ||
		parsed.Query().Get("stdout") != "true" ||
		parsed.Query().Get("tty") != "true" {
		t.Fatalf("attach URL = %s", attachURL)
	}

	created, deleteCount := fixture.snapshot()
	if created == nil || deleteCount != 1 {
		t.Fatalf("helper lifecycle = created %#v, deletes %d", created, deleteCount)
	}
	if created.GenerateName != "kmgr-node-shell-" || created.Spec.NodeName != "worker-a" ||
		!created.Spec.HostPID || !created.Spec.HostNetwork ||
		created.Spec.RestartPolicy != corev1.RestartPolicyNever ||
		created.Spec.AutomountServiceAccountToken == nil ||
		*created.Spec.AutomountServiceAccountToken ||
		created.Spec.TerminationGracePeriodSeconds == nil ||
		*created.Spec.TerminationGracePeriodSeconds != 0 {
		t.Fatalf("helper Pod security/lifecycle spec = %#v", created.Spec)
	}
	if len(created.Spec.Containers) != 1 {
		t.Fatalf("helper containers = %#v", created.Spec.Containers)
	}
	container := created.Spec.Containers[0]
	wantCommand := []string{
		"nsenter", "--target", "1", "--mount", "--uts", "--ipc", "--net", "--pid", "--",
		"bash", "-l",
	}
	if container.Name != nodeShellContainerName ||
		container.Image != "registry.example/node-shell:1" ||
		!reflect.DeepEqual(container.Command, wantCommand) ||
		container.SecurityContext == nil || container.SecurityContext.Privileged == nil ||
		!*container.SecurityContext.Privileged || !container.Stdin || !container.StdinOnce ||
		!container.TTY {
		t.Fatalf("helper container = %#v", container)
	}
	if len(container.Resources.Requests) != 0 || len(container.Resources.Limits) != 0 {
		t.Fatalf("helper resources = %#v", container.Resources)
	}
	if len(created.Spec.Tolerations) != 2 ||
		created.Spec.Tolerations[0].Key != "CriticalAddonsOnly" ||
		created.Spec.Tolerations[0].Operator != corev1.TolerationOpExists ||
		created.Spec.Tolerations[1].Operator != corev1.TolerationOpExists ||
		created.Spec.Tolerations[1].Effect != corev1.TaintEffectNoExecute {
		t.Fatalf("helper tolerations = %#v", created.Spec.Tolerations)
	}
}

func TestClientGoRunnerHonorsNodeShellStartupTimeoutAndCleansUp(t *testing.T) {
	t.Parallel()
	fixture := newNodeShellAPIFixture(t)
	fixture.helperStatus = corev1.PodStatus{Phase: corev1.PodPending}
	defer fixture.close()
	core, config := fixture.client(t)
	runner := ClientGoRunner{
		Core: core, Config: config, NodeShellStartupTimeout: 25 * time.Millisecond,
	}

	err := runner.Run(context.Background(), testNodeShellStart(), RunOptions{})
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("startup timeout error = %v, want deadline exceeded", err)
	}
	_, deleteCount := fixture.snapshot()
	if deleteCount != 1 {
		t.Fatalf("helper delete count after startup timeout = %d", deleteCount)
	}
}

func TestClientGoRunnerDeletesNodeShellHelperAfterCancellation(t *testing.T) {
	t.Parallel()
	fixture := newNodeShellAPIFixture(t)
	defer fixture.close()
	core, config := fixture.client(t)
	attached := make(chan struct{})
	runner := ClientGoRunner{
		Core: core, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(
			_ *rest.Config, _ string, ready func(),
		) (remotecommand.Executor, error) {
			return executorFunc(func(ctx context.Context, _ remotecommand.StreamOptions) error {
				ready()
				close(attached)
				<-ctx.Done()
				return ctx.Err()
			}), nil
		}),
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runner.Run(ctx, testNodeShellStart(), RunOptions{}) }()
	<-attached
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled node shell = %v", err)
	}
	_, deleteCount := fixture.snapshot()
	if deleteCount != 1 {
		t.Fatalf("helper delete count after cancellation = %d", deleteCount)
	}
}

func TestClientGoRunnerReportsNodeShellImagePullFailureAndCleansUp(t *testing.T) {
	t.Parallel()
	fixture := newNodeShellAPIFixture(t)
	fixture.helperStatus = corev1.PodStatus{
		Phase: corev1.PodPending,
		ContainerStatuses: []corev1.ContainerStatus{{
			Name: nodeShellContainerName,
			State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{
				Reason: "ImagePullBackOff",
			}},
		}},
	}
	defer fixture.close()
	core, config := fixture.client(t)
	factoryCalled := false
	runner := ClientGoRunner{
		Core: core, Config: config,
		ExecutorFactory: ExecutorFactoryFunc(func(
			*rest.Config, string, func(),
		) (remotecommand.Executor, error) {
			factoryCalled = true
			return nil, errors.New("unexpected attach")
		}),
	}
	err := runner.Run(context.Background(), testNodeShellStart(), RunOptions{})
	var startError *NodeShellPodStartError
	if !errors.As(err, &startError) || startError.Reason != "ImagePullBackOff" {
		t.Fatalf("image pull error = %#v", err)
	}
	if factoryCalled {
		t.Fatal("attach was attempted after image pull failure")
	}
	_, deleteCount := fixture.snapshot()
	if deleteCount != 1 {
		t.Fatalf("helper delete count after image failure = %d", deleteCount)
	}
}

func TestClientGoRunnerRejectsRecreatedAndWindowsNodes(t *testing.T) {
	t.Parallel()
	for _, test := range []struct {
		name  string
		uid   types.UID
		os    string
		check func(error) bool
	}{
		{
			name: "recreated", uid: "replacement-node-uid", os: "linux",
			check: func(err error) bool {
				var mismatch *NodeUIDMismatchError
				return errors.As(err, &mismatch) && mismatch.Expected == "node-uid" &&
					mismatch.Actual == "replacement-node-uid"
			},
		},
		{
			name: "windows", uid: "node-uid", os: "windows",
			check: func(err error) bool { return errors.Is(err, ErrWindowsNodeShellUnsupported) },
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			fixture := newNodeShellAPIFixture(t)
			fixture.nodeUID = test.uid
			fixture.nodeOS = test.os
			defer fixture.close()
			core, config := fixture.client(t)
			runner := ClientGoRunner{Core: core, Config: config}
			err := runner.Run(context.Background(), testNodeShellStart(), RunOptions{})
			if !test.check(err) {
				t.Fatalf("Run error = %#v", err)
			}
			created, _ := fixture.snapshot()
			if created != nil {
				t.Fatalf("helper was created for rejected Node: %#v", created)
			}
		})
	}
}

func testNodeShellStart() StartRequest {
	return StartRequest{
		SessionID: "cluster-session", ExecSessionID: "node-terminal", Generation: 1,
		NodeShell: &NodeShellTarget{
			Node: Identity{
				SessionID: "cluster-session", Version: "v1", Resource: "nodes",
				Name: "worker-a", UID: "node-uid",
			},
			Namespace: "ops", Image: "registry.example/node-shell:1",
		},
		Command: []string{"bash", "-l"}, TTY: true, Stdin: true,
		InitialSize: &TerminalSize{Columns: 80, Rows: 24},
	}
}

type nodeShellAPIFixture struct {
	t            *testing.T
	server       *httptest.Server
	mu           sync.Mutex
	nodeUID      types.UID
	nodeOS       string
	helperStatus corev1.PodStatus
	created      *corev1.Pod
	deleteCount  int
}

func newNodeShellAPIFixture(t *testing.T) *nodeShellAPIFixture {
	t.Helper()
	fixture := &nodeShellAPIFixture{
		t: t, nodeUID: "node-uid", nodeOS: "linux",
		helperStatus: corev1.PodStatus{
			Phase: corev1.PodRunning,
			ContainerStatuses: []corev1.ContainerStatus{{
				Name:  nodeShellContainerName,
				State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{}},
			}},
		},
	}
	fixture.server = httptest.NewServer(http.HandlerFunc(fixture.serveHTTP))
	return fixture
}

func (f *nodeShellAPIFixture) close() { f.server.Close() }

func (f *nodeShellAPIFixture) client(t *testing.T) (coreclient.CoreV1Interface, *rest.Config) {
	t.Helper()
	config := &rest.Config{
		Host: f.server.URL,
		ContentConfig: rest.ContentConfig{
			ContentType: "application/json", AcceptContentTypes: "application/json",
		},
	}
	core, err := coreclient.NewForConfig(config)
	if err != nil {
		t.Fatalf("NewForConfig: %v", err)
	}
	return core, config
}

func (f *nodeShellAPIFixture) snapshot() (*corev1.Pod, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.created.DeepCopy(), f.deleteCount
}

func (f *nodeShellAPIFixture) serveHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Content-Type", "application/json")
	switch {
	case request.Method == http.MethodGet && request.URL.Path == "/api/v1/nodes/worker-a":
		f.mu.Lock()
		nodeUID, nodeOS := f.nodeUID, f.nodeOS
		f.mu.Unlock()
		_ = json.NewEncoder(writer).Encode(&corev1.Node{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Node"},
			ObjectMeta: metav1.ObjectMeta{
				Name: "worker-a", UID: nodeUID,
				Labels: map[string]string{corev1.LabelOSStable: nodeOS},
			},
		})
	case request.Method == http.MethodPost && request.URL.Path == "/api/v1/namespaces/ops/pods":
		var pod corev1.Pod
		if err := json.NewDecoder(request.Body).Decode(&pod); err != nil {
			f.t.Errorf("decode helper Pod: %v", err)
			writer.WriteHeader(http.StatusBadRequest)
			return
		}
		f.mu.Lock()
		f.created = pod.DeepCopy()
		f.mu.Unlock()
		pod.Name = "helper-1"
		pod.UID = "helper-uid"
		_ = json.NewEncoder(writer).Encode(&pod)
	case request.Method == http.MethodGet && request.URL.Path == "/api/v1/namespaces/ops/pods/helper-1":
		f.mu.Lock()
		status := f.helperStatus.DeepCopy()
		f.mu.Unlock()
		_ = json.NewEncoder(writer).Encode(&corev1.Pod{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
			ObjectMeta: metav1.ObjectMeta{
				Namespace: "ops", Name: "helper-1", UID: "helper-uid",
			},
			Status: *status,
		})
	case request.Method == http.MethodDelete && request.URL.Path == "/api/v1/namespaces/ops/pods/helper-1":
		f.mu.Lock()
		f.deleteCount++
		f.mu.Unlock()
		_ = json.NewEncoder(writer).Encode(&metav1.Status{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"},
			Status:   metav1.StatusSuccess,
		})
	default:
		f.t.Errorf("unexpected Kubernetes request: %s %s", request.Method, request.URL.Path)
		writer.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(writer).Encode(&metav1.Status{
			TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Status"},
			Status:   metav1.StatusFailure, Reason: metav1.StatusReasonNotFound,
			Code: http.StatusNotFound,
		})
	}
}
