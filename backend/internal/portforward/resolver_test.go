package portforward

import (
	"context"
	"errors"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes/fake"
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
