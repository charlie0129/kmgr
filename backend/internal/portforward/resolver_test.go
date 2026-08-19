package portforward

import (
	"context"
	"errors"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	dynamicfake "k8s.io/client-go/dynamic/fake"
	"k8s.io/client-go/kubernetes/fake"
	clienttesting "k8s.io/client-go/testing"
)

func TestClientGoResolverPinsDirectPodUID(t *testing.T) {
	t.Parallel()
	client := fake.NewClientset(&corev1.Pod{ObjectMeta: metav1.ObjectMeta{
		Namespace: "ns", Name: "pod", UID: "new-uid",
	}})
	resolver := ClientGoTargetResolver{Core: client.CoreV1()}
	_, err := resolver.Resolve(context.Background(), podIdentity("pod", "old-uid"), 8080)
	if !errors.Is(err, ErrPodRecreated) {
		t.Fatalf("Resolve error = %v", err)
	}
}

func TestClientGoResolverPinsServiceUID(t *testing.T) {
	t.Parallel()
	client := fake.NewClientset(&corev1.Service{ObjectMeta: metav1.ObjectMeta{
		Namespace: "ns", Name: "api", UID: "new-uid",
	}})
	resolver := ClientGoTargetResolver{Core: client.CoreV1()}
	_, err := resolver.Resolve(context.Background(), serviceIdentity("api", "old-uid"), 80)
	if !errors.Is(err, ErrServiceRecreated) {
		t.Fatalf("Resolve error = %v, want ErrServiceRecreated", err)
	}
}

func TestClientGoResolverSelectsReadyServicePodAndNamedTargetPort(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "api"},
			Ports:    []corev1.ServicePort{{Port: 80, TargetPort: intstr.FromString("http")}},
		},
	}
	terminating := readyPod("terminating", "a", 8081)
	terminating.DeletionTimestamp = &metav1.Time{Time: metav1.Now().Time}
	notReady := readyPod("not-ready", "b", 8082)
	notReady.Status.Conditions[0].Status = corev1.ConditionFalse
	ready := readyPod("ready", "c", 8083)
	client := fake.NewClientset(service, terminating, notReady, ready)
	resolver := ClientGoTargetResolver{Core: client.CoreV1()}
	resolved, err := resolver.Resolve(context.Background(), serviceIdentity("api", "service-uid"), 80)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Pod.Name != "ready" || resolved.Pod.UID != "c" || resolved.RemotePort != 8083 {
		t.Fatalf("resolved = %#v", resolved)
	}
}

func TestClientGoResolverUsesEndpointSliceAndOneExactPodGet(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec: corev1.ServiceSpec{
			Ports: []corev1.ServicePort{{Port: 80, TargetPort: intstr.FromString("http")}},
		},
	}
	pod := readyPod("ready", "pod-uid", 8083)
	coreClient := fake.NewClientset(service, pod)
	endpointClient := newEndpointSliceClient(t, service.Name, pod, true)

	resolved, err := (ClientGoTargetResolver{
		Core: coreClient.CoreV1(), Dynamic: endpointClient,
	}).Resolve(context.Background(), serviceIdentity("api", "service-uid"), 80)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Pod.Name != pod.Name || resolved.Pod.UID != pod.UID || resolved.RemotePort != 8083 {
		t.Fatalf("resolved = %#v", resolved)
	}
	if got := actionCount(coreClient.Actions(), "get", "pods"); got != 1 {
		t.Fatalf("Pod GET calls = %d, want 1", got)
	}
	if got := actionCount(coreClient.Actions(), "list", "pods"); got != 0 {
		t.Fatalf("Pod LIST calls = %d, want 0", got)
	}
	actions := endpointClient.Actions()
	if len(actions) != 1 || actions[0].GetVerb() != "list" ||
		actions[0].GetResource().Resource != "endpointslices" {
		t.Fatalf("EndpointSlice actions = %#v", actions)
	}
	listAction, ok := actions[0].(clienttesting.ListAction)
	if !ok || listAction.GetListRestrictions().Labels.String() !=
		discoveryv1.LabelServiceName+"=api" {
		t.Fatalf("EndpointSlice list action = %#v", actions[0])
	}
}

func TestClientGoResolverFallsBackWhenEndpointSlicesAreForbidden(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "api"},
			Ports:    []corev1.ServicePort{{Port: 80, TargetPort: intstr.FromString("http")}},
		},
	}
	pod := readyPod("ready", "pod-uid", 8083)
	coreClient := fake.NewClientset(service, pod)
	endpointClient := newEndpointSliceClient(t, service.Name, pod, true)
	endpointClient.PrependReactor("list", "endpointslices", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewForbidden(
			schema.GroupResource{Group: "discovery.k8s.io", Resource: "endpointslices"},
			"", errors.New("denied"),
		)
	})

	resolved, err := (ClientGoTargetResolver{
		Core: coreClient.CoreV1(), Dynamic: endpointClient,
	}).Resolve(context.Background(), serviceIdentity("api", "service-uid"), 80)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Pod.UID != pod.UID || resolved.RemotePort != 8083 {
		t.Fatalf("resolved = %#v", resolved)
	}
	if got := actionCount(coreClient.Actions(), "list", "pods"); got != 1 {
		t.Fatalf("Pod LIST calls = %d, want compatibility fallback", got)
	}
}

func TestClientGoResolverDoesNotBroadenOnTransientEndpointSliceFailure(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec:       corev1.ServiceSpec{Selector: map[string]string{"app": "api"}},
	}
	pod := readyPod("ready", "pod-uid", 8083)
	coreClient := fake.NewClientset(service, pod)
	endpointClient := newEndpointSliceClient(t, service.Name, pod, true)
	endpointClient.PrependReactor("list", "endpointslices", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewInternalError(errors.New("temporarily unavailable"))
	})

	_, err := (ClientGoTargetResolver{
		Core: coreClient.CoreV1(), Dynamic: endpointClient,
	}).Resolve(context.Background(), serviceIdentity("api", "service-uid"), 80)
	if err == nil || !strings.Contains(err.Error(), "temporarily unavailable") {
		t.Fatalf("Resolve error = %v", err)
	}
	if got := actionCount(coreClient.Actions(), "list", "pods"); got != 0 {
		t.Fatalf("Pod LIST calls = %d, want no expensive transient fallback", got)
	}
}

func TestClientGoResolverServiceAllowsManualPodPort(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec:       corev1.ServiceSpec{Selector: map[string]string{"app": "api"}},
	}
	client := fake.NewClientset(service, readyPod("ready", "uid", 8080))
	resolver := ClientGoTargetResolver{Core: client.CoreV1()}
	resolved, err := resolver.Resolve(context.Background(), serviceIdentity("api", "service-uid"), 9000)
	if err != nil || resolved.RemotePort != 9000 {
		t.Fatalf("resolved = %#v, error = %v", resolved, err)
	}
}

func TestClientGoResolverPagesServicePodsAndRetainsDeterministicBest(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app": "api"},
			Ports:    []corev1.ServicePort{{Port: 80, TargetPort: intstr.FromString("http")}},
		},
	}
	client := fake.NewClientset(service)
	var options []metav1.ListOptions
	client.Fake.PrependReactor("list", "pods", func(action clienttesting.Action) (bool, runtime.Object, error) {
		listAction, ok := action.(interface{ GetListOptions() metav1.ListOptions })
		if !ok {
			t.Fatalf("list action does not expose options: %T", action)
		}
		current := listAction.GetListOptions()
		options = append(options, current)
		switch current.Continue {
		case "":
			return true, &corev1.PodList{
				ListMeta: metav1.ListMeta{Continue: "page-two"},
				Items:    []corev1.Pod{*readyPod("later", "z-uid", 8081)},
			}, nil
		case "page-two":
			return true, &corev1.PodList{
				Items: []corev1.Pod{*readyPod("chosen", "a-uid", 8082)},
			}, nil
		default:
			t.Fatalf("unexpected continuation %q", current.Continue)
			return true, nil, nil
		}
	})

	resolved, err := (ClientGoTargetResolver{Core: client.CoreV1()}).Resolve(
		context.Background(), serviceIdentity("api", "service-uid"), 80,
	)
	if err != nil {
		t.Fatal(err)
	}
	if resolved.Pod.Name != "chosen" || resolved.Pod.UID != "a-uid" || resolved.RemotePort != 8082 {
		t.Fatalf("resolved = %#v", resolved)
	}
	if len(options) != 2 || options[0].Limit != servicePodListPageSize ||
		options[0].Continue != "" || options[1].Continue != "page-two" ||
		!strings.Contains(options[0].FieldSelector, "status.phase!=Succeeded") ||
		!strings.Contains(options[0].FieldSelector, "status.phase!=Failed") {
		t.Fatalf("list options = %#v", options)
	}
}

func TestClientGoResolverRejectsRepeatedPodContinuationToken(t *testing.T) {
	t.Parallel()
	service := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: "api", UID: "service-uid"},
		Spec:       corev1.ServiceSpec{Selector: map[string]string{"app": "api"}},
	}
	client := fake.NewClientset(service)
	client.Fake.PrependReactor("list", "pods", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, &corev1.PodList{ListMeta: metav1.ListMeta{Continue: "same"}}, nil
	})
	_, err := (ClientGoTargetResolver{Core: client.CoreV1()}).Resolve(
		context.Background(), serviceIdentity("api", "service-uid"), 80,
	)
	if err == nil || !strings.Contains(err.Error(), "repeated a continuation token") {
		t.Fatalf("Resolve error = %v", err)
	}
}

func readyPod(name string, uid types.UID, port int32) *corev1.Pod {
	return &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Namespace: "ns", Name: name, UID: uid, Labels: map[string]string{"app": "api"}},
		Spec: corev1.PodSpec{Containers: []corev1.Container{{
			Name: "app", Ports: []corev1.ContainerPort{{Name: "http", ContainerPort: port}},
		}}},
		Status: corev1.PodStatus{
			Phase:      corev1.PodRunning,
			Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
		},
	}
}

func newEndpointSliceClient(
	t *testing.T,
	serviceName string,
	pod *corev1.Pod,
	ready bool,
) *dynamicfake.FakeDynamicClient {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := discoveryv1.AddToScheme(scheme); err != nil {
		t.Fatal(err)
	}
	return dynamicfake.NewSimpleDynamicClient(scheme, &discoveryv1.EndpointSlice{
		TypeMeta: metav1.TypeMeta{
			APIVersion: discoveryv1.SchemeGroupVersion.String(), Kind: "EndpointSlice",
		},
		ObjectMeta: metav1.ObjectMeta{
			Namespace: pod.Namespace, Name: serviceName + "-slice",
			Labels: map[string]string{discoveryv1.LabelServiceName: serviceName},
		},
		AddressType: discoveryv1.AddressTypeIPv4,
		Endpoints: []discoveryv1.Endpoint{{
			Conditions: discoveryv1.EndpointConditions{Ready: &ready},
			TargetRef: &corev1.ObjectReference{
				Kind: "Pod", Namespace: pod.Namespace, Name: pod.Name, UID: pod.UID,
			},
		}},
	})
}

func actionCount(actions []clienttesting.Action, verb, resource string) int {
	count := 0
	for _, action := range actions {
		if action.GetVerb() == verb && action.GetResource().Resource == resource {
			count++
		}
	}
	return count
}
