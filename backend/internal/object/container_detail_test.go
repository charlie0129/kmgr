package object

import (
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
)

func TestPodContainerDetailsProjectRuntimeStateReadinessRestartsAndPorts(t *testing.T) {
	t.Parallel()
	pod := &corev1.Pod{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{
				{Name: "api", Ports: []corev1.ContainerPort{
					{Name: "http", ContainerPort: 8080, Protocol: corev1.ProtocolTCP},
					{ContainerPort: 8443, Protocol: corev1.ProtocolTCP},
				}},
				{Name: "sidecar"},
			},
			InitContainers: []corev1.Container{{Name: "migrate"}},
			EphemeralContainers: []corev1.EphemeralContainer{{
				EphemeralContainerCommon: corev1.EphemeralContainerCommon{Name: "debugger"},
			}},
		},
		Status: corev1.PodStatus{
			ContainerStatuses: []corev1.ContainerStatus{{
				Name: "api", RestartCount: 4,
				State: corev1.ContainerState{Waiting: &corev1.ContainerStateWaiting{
					Reason: "CrashLoopBackOff", Message: "retrying the failed container",
				}},
			}},
			InitContainerStatuses: []corev1.ContainerStatus{{
				Name: "migrate", Ready: true,
				State: corev1.ContainerState{Terminated: &corev1.ContainerStateTerminated{
					Reason: "Completed", ExitCode: 0,
					FinishedAt: metav1.NewTime(time.Unix(100, 0)),
				}},
			}},
			EphemeralContainerStatuses: []corev1.ContainerStatus{{
				Name: "debugger", Ready: true,
				State: corev1.ContainerState{Running: &corev1.ContainerStateRunning{
					StartedAt: metav1.NewTime(time.Unix(200, 0)),
				}},
			}},
		},
	}
	raw, err := runtime.DefaultUnstructuredConverter.ToUnstructured(pod)
	if err != nil {
		t.Fatal(err)
	}
	details := podContainerDetails(&unstructured.Unstructured{Object: raw})
	if len(details) != 4 {
		t.Fatalf("container details = %#v", details)
	}
	byName := make(map[string]ContainerDetail, len(details))
	for _, detail := range details {
		byName[detail.Name] = detail
	}
	api := byName["api"]
	if api.Kind != ContainerRegular || api.Status != "Waiting: CrashLoopBackOff" ||
		api.StatusSeverity != ContainerStatusCritical || api.Ready || api.RestartCount != 4 ||
		!strings.Contains(api.StatusTooltip, "retrying the failed container") ||
		len(api.Ports) != 2 || api.Ports[0] != "http: 8080/TCP" || api.Ports[1] != "8443/TCP" {
		t.Fatalf("api detail = %#v", api)
	}
	if sidecar := byName["sidecar"]; sidecar.Status != "Pending" ||
		sidecar.StatusSeverity != ContainerStatusWarning || sidecar.Ready || sidecar.RestartCount != 0 {
		t.Fatalf("sidecar detail = %#v", sidecar)
	}
	if migrate := byName["migrate"]; migrate.Kind != ContainerInit ||
		migrate.Status != "Terminated: Completed" || migrate.StatusSeverity != ContainerStatusNormal ||
		!migrate.Ready {
		t.Fatalf("init detail = %#v", migrate)
	}
	if debugger := byName["debugger"]; debugger.Kind != ContainerEphemeral ||
		debugger.Status != "Running" || !debugger.Ready {
		t.Fatalf("ephemeral detail = %#v", debugger)
	}
}
