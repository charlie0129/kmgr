package object

import (
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
)

type ContainerKind uint8

const (
	ContainerRegular ContainerKind = iota + 1
	ContainerInit
	ContainerEphemeral
)

type ContainerStatusSeverity uint8

const (
	ContainerStatusNormal ContainerStatusSeverity = iota + 1
	ContainerStatusWarning
	ContainerStatusCritical
	ContainerStatusMuted
)

// ContainerDetail is the bounded non-sensitive subset of a Pod container
// needed by the native container list. Images, commands, environment values,
// mounts, and the raw Pod object intentionally never enter this model.
type ContainerDetail struct {
	Name           string
	Kind           ContainerKind
	Status         string
	StatusTooltip  string
	StatusSeverity ContainerStatusSeverity
	Ready          bool
	RestartCount   int32
	Ports          []string
}

type declaredContainer struct {
	name  string
	kind  ContainerKind
	ports []corev1.ContainerPort
}

func podContainerDetails(object *unstructured.Unstructured) []ContainerDetail {
	if object == nil {
		return nil
	}
	var pod corev1.Pod
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(object.Object, &pod); err != nil {
		return nil
	}

	declared := make([]declaredContainer, 0,
		len(pod.Spec.Containers)+len(pod.Spec.InitContainers)+len(pod.Spec.EphemeralContainers))
	for _, container := range pod.Spec.Containers {
		declared = append(declared, declaredContainer{
			name: container.Name, kind: ContainerRegular, ports: container.Ports,
		})
	}
	for _, container := range pod.Spec.InitContainers {
		declared = append(declared, declaredContainer{
			name: container.Name, kind: ContainerInit, ports: container.Ports,
		})
	}
	for _, container := range pod.Spec.EphemeralContainers {
		declared = append(declared, declaredContainer{
			name: container.Name, kind: ContainerEphemeral, ports: container.Ports,
		})
	}

	statuses := map[ContainerKind]map[string]corev1.ContainerStatus{
		ContainerRegular:   containerStatusesByName(pod.Status.ContainerStatuses),
		ContainerInit:      containerStatusesByName(pod.Status.InitContainerStatuses),
		ContainerEphemeral: containerStatusesByName(pod.Status.EphemeralContainerStatuses),
	}
	result := make([]ContainerDetail, 0, min(len(declared), maximumSummaryContainers))
	seenNames := make(map[string]struct{}, len(declared))
	remainingPorts := maximumSummaryPorts
	for _, container := range declared {
		if len(result) == maximumSummaryContainers {
			break
		}
		if !validSummaryToken(container.name, maximumSummaryNameBytes) {
			continue
		}
		if _, duplicate := seenNames[container.name]; duplicate {
			continue
		}
		seenNames[container.name] = struct{}{}
		status, found := statuses[container.kind][container.name]
		text, tooltip, severity := containerStatusPresentation(status, found)
		detail := ContainerDetail{
			Name:           container.name,
			Kind:           container.kind,
			Status:         text,
			StatusTooltip:  tooltip,
			StatusSeverity: severity,
			Ports:          containerPortDisplays(container.ports, &remainingPorts),
		}
		if found {
			detail.Ready = status.Ready
			detail.RestartCount = max(status.RestartCount, 0)
		}
		result = append(result, detail)
	}
	return result
}

func containerStatusesByName(values []corev1.ContainerStatus) map[string]corev1.ContainerStatus {
	result := make(map[string]corev1.ContainerStatus, len(values))
	for _, value := range values {
		if _, duplicate := result[value.Name]; !duplicate {
			result[value.Name] = value
		}
	}
	return result
}

func containerStatusPresentation(
	status corev1.ContainerStatus,
	found bool,
) (text, tooltip string, severity ContainerStatusSeverity) {
	if !found {
		return "Pending", "Kubernetes has not reported this container's runtime state", ContainerStatusWarning
	}
	state := status.State
	switch {
	case state.Running != nil:
		parts := []string{"State: Running"}
		if !state.Running.StartedAt.IsZero() {
			parts = append(parts, "Started: "+state.Running.StartedAt.Time.Format(time.RFC3339))
		}
		return "Running", strings.Join(parts, "\n"), ContainerStatusNormal
	case state.Waiting != nil:
		text = "Waiting"
		parts := []string{"State: Waiting"}
		if reason := boundedSummaryText(state.Waiting.Reason); reason != "" {
			text += ": " + reason
			parts = append(parts, "Reason: "+reason)
		}
		if message := boundedSummaryText(state.Waiting.Message); message != "" {
			parts = append(parts, "Message: "+message)
		}
		severity = ContainerStatusWarning
		folded := strings.ToLower(text)
		if strings.Contains(folded, "crash") || strings.Contains(folded, "error") ||
			strings.Contains(folded, "fail") || strings.Contains(folded, "backoff") {
			severity = ContainerStatusCritical
		}
		return boundedSummaryText(text), boundedSummaryText(strings.Join(parts, "\n")), severity
	case state.Terminated != nil:
		text = "Terminated"
		parts := []string{
			"State: Terminated",
			fmt.Sprintf("Exit code: %d", state.Terminated.ExitCode),
		}
		if reason := boundedSummaryText(state.Terminated.Reason); reason != "" {
			text += ": " + reason
			parts = append(parts, "Reason: "+reason)
		}
		if state.Terminated.Signal != 0 {
			parts = append(parts, fmt.Sprintf("Signal: %d", state.Terminated.Signal))
		}
		if !state.Terminated.FinishedAt.IsZero() {
			parts = append(parts, "Finished: "+state.Terminated.FinishedAt.Time.Format(time.RFC3339))
		}
		if message := boundedSummaryText(state.Terminated.Message); message != "" {
			parts = append(parts, "Message: "+message)
		}
		severity = ContainerStatusNormal
		if state.Terminated.ExitCode != 0 {
			severity = ContainerStatusCritical
		}
		return boundedSummaryText(text), boundedSummaryText(strings.Join(parts, "\n")), severity
	default:
		return "Unknown", "Kubernetes reported no running, waiting, or terminated state", ContainerStatusMuted
	}
}

func containerPortDisplays(values []corev1.ContainerPort, remaining *int) []string {
	if remaining == nil || *remaining <= 0 {
		return nil
	}
	result := make([]string, 0, min(len(values), *remaining))
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if *remaining == 0 {
			break
		}
		if value.ContainerPort <= 0 || value.ContainerPort > 65535 {
			continue
		}
		if value.Name != "" && !validSummaryToken(value.Name, maximumSummaryPortNameBytes) {
			continue
		}
		protocol := value.Protocol
		if protocol == "" {
			protocol = corev1.ProtocolTCP
		}
		display := fmt.Sprintf("%d/%s", value.ContainerPort, protocol)
		if value.Name != "" {
			display = value.Name + ": " + display
		}
		if _, duplicate := seen[display]; duplicate {
			continue
		}
		seen[display] = struct{}{}
		result = append(result, display)
		*remaining = *remaining - 1
	}
	return result
}
