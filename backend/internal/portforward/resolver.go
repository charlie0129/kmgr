package portforward

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes/typed/core/v1"
)

type ClusterSessions struct {
	Sessions *cluster.SessionRegistry
}

func (r ClusterSessions) ResolveSession(sessionID string) (Session, error) {
	if r.Sessions == nil {
		return Session{}, ErrSessionNotFound
	}
	session, lease, found := r.Sessions.Acquire(sessionID)
	if !found {
		return Session{}, ErrSessionNotFound
	}
	if session.Core() == nil || session.Core().RESTClient() == nil || session.RESTConfig() == nil {
		lease.Release()
		return Session{}, errors.New("Kubernetes port-forward client is unavailable")
	}
	resolver := ClientGoTargetResolver{Core: session.Core(), Dynamic: session.Dynamic()}
	return Session{
		ContextName: session.Context().Name,
		Resolver:    resolver,
		Forwarder: ClientGoForwarder{
			Config: session.RESTConfig(), RESTClient: session.Core().RESTClient(), Core: session.Core(),
		},
		Release: lease.Release,
	}, nil
}

type ClientGoTargetResolver struct {
	Core    v1.CoreV1Interface
	Dynamic dynamic.Interface
}

const (
	serviceEndpointSliceListPageSize int64 = 500
	servicePodListPageSize           int64 = 500
)

var endpointSliceResource = schema.GroupVersionResource{
	Group: "discovery.k8s.io", Version: "v1", Resource: "endpointslices",
}

func (r ClientGoTargetResolver) Resolve(ctx context.Context, target Identity, remotePort uint16) (ResolvedTarget, error) {
	if r.Core == nil {
		return ResolvedTarget{}, errors.New("Kubernetes Core client is unavailable")
	}
	switch {
	case target.IsPod():
		pod, err := r.Core.Pods(target.Namespace).Get(ctx, target.Name, metav1.GetOptions{})
		if err != nil {
			return ResolvedTarget{}, err
		}
		if pod.UID != target.UID {
			return ResolvedTarget{}, fmt.Errorf("%w: expected UID %q, found %q", ErrPodRecreated, target.UID, pod.UID)
		}
		return ResolvedTarget{Pod: Identity{
			SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: pod.Namespace,
			Name: pod.Name, UID: pod.UID,
		}, RemotePort: remotePort}, nil
	case target.IsService():
		service, err := r.Core.Services(target.Namespace).Get(ctx, target.Name, metav1.GetOptions{})
		if err != nil {
			return ResolvedTarget{}, err
		}
		if service.UID != target.UID {
			return ResolvedTarget{}, fmt.Errorf("%w: expected UID %q, found %q", ErrServiceRecreated, target.UID, service.UID)
		}
		if r.Dynamic != nil {
			resolved, found, err := r.resolveServiceEndpointSlice(ctx, target, *service, remotePort)
			switch {
			case err == nil && found:
				return resolved, nil
			case err != nil && !endpointSliceFallbackAllowed(err):
				return ResolvedTarget{}, err
			}
		}
		return r.resolveServicePodList(ctx, target, *service, remotePort)
	default:
		return ResolvedTarget{}, fmt.Errorf("%w: target must be a Pod or Service", ErrInvalidRequest)
	}
}

type endpointPodCandidate struct {
	name     string
	uid      types.UID
	priority int
}

// resolveServiceEndpointSlice uses the compact service endpoint index to pick
// one Ready Pod, then performs one exact Pod GET to pin identity, readiness,
// and named target-port resolution. The caller retains the legacy
// label-selected Pod LIST only as a compatibility fallback for clusters or
// identities that cannot expose EndpointSlices, stale slices, and services
// whose endpoints do not target Pods.
func (r ClientGoTargetResolver) resolveServiceEndpointSlice(
	ctx context.Context,
	target Identity,
	service corev1.Service,
	remotePort uint16,
) (ResolvedTarget, bool, error) {
	candidates := make(map[types.UID]endpointPodCandidate)
	continuation := ""
	seenContinuations := make(map[string]struct{})
	for {
		items, err := r.Dynamic.Resource(endpointSliceResource).Namespace(target.Namespace).List(
			ctx,
			metav1.ListOptions{
				LabelSelector: labels.Set{discoveryv1.LabelServiceName: service.Name}.AsSelector().String(),
				Limit:         serviceEndpointSliceListPageSize,
				Continue:      continuation,
			},
		)
		if err != nil {
			return ResolvedTarget{}, false, fmt.Errorf("list Service EndpointSlices: %w", err)
		}
		for index := range items.Items {
			var endpointSlice discoveryv1.EndpointSlice
			if err := runtime.DefaultUnstructuredConverter.FromUnstructured(
				items.Items[index].Object, &endpointSlice,
			); err != nil {
				return ResolvedTarget{}, false, fmt.Errorf("decode Service EndpointSlice: %w", err)
			}
			for endpointIndex := range endpointSlice.Endpoints {
				endpoint := &endpointSlice.Endpoints[endpointIndex]
				if endpoint.Conditions.Terminating != nil && *endpoint.Conditions.Terminating {
					continue
				}
				if endpoint.Conditions.Ready != nil && !*endpoint.Conditions.Ready {
					continue
				}
				ref := endpoint.TargetRef
				if ref == nil || ref.Kind != "Pod" || ref.Name == "" || ref.UID == "" ||
					(ref.Namespace != "" && ref.Namespace != target.Namespace) {
					continue
				}
				priority := 1
				if endpoint.Conditions.Ready != nil && *endpoint.Conditions.Ready {
					priority = 0
				}
				candidate := endpointPodCandidate{name: ref.Name, uid: ref.UID, priority: priority}
				if previous, exists := candidates[ref.UID]; !exists || candidate.priority < previous.priority ||
					(candidate.priority == previous.priority && candidate.name < previous.name) {
					candidates[ref.UID] = candidate
				}
			}
		}
		next := items.GetContinue()
		if next == "" {
			break
		}
		if _, duplicate := seenContinuations[next]; duplicate {
			return ResolvedTarget{}, false, errors.New("Kubernetes EndpointSlice pagination repeated a continuation token")
		}
		seenContinuations[next] = struct{}{}
		continuation = next
	}
	if len(candidates) == 0 {
		return ResolvedTarget{}, false, nil
	}
	ordered := make([]endpointPodCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		ordered = append(ordered, candidate)
	}
	sort.Slice(ordered, func(left, right int) bool {
		if ordered[left].priority != ordered[right].priority {
			return ordered[left].priority < ordered[right].priority
		}
		if ordered[left].uid != ordered[right].uid {
			return string(ordered[left].uid) < string(ordered[right].uid)
		}
		return ordered[left].name < ordered[right].name
	})
	selected := ordered[0]
	pod, err := r.Core.Pods(target.Namespace).Get(ctx, selected.name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsForbidden(err) || apierrors.IsNotFound(err) {
			return ResolvedTarget{}, false, nil
		}
		return ResolvedTarget{}, false, fmt.Errorf("get EndpointSlice Pod: %w", err)
	}
	if pod.UID != selected.uid || pod.DeletionTimestamp != nil ||
		pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded ||
		!podReady(pod.Status.Conditions) {
		return ResolvedTarget{}, false, nil
	}
	resolvedPort, err := serviceTargetPort(service.Spec.Ports, *pod, remotePort)
	if err != nil {
		return ResolvedTarget{}, false, err
	}
	return ResolvedTarget{
		Pod: Identity{
			SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: pod.Namespace,
			Name: pod.Name, UID: pod.UID,
		},
		RemotePort: resolvedPort,
	}, true, nil
}

func endpointSliceFallbackAllowed(err error) bool {
	return apierrors.IsForbidden(err) || apierrors.IsNotFound(err) ||
		apierrors.IsMethodNotSupported(err)
}

func (r ClientGoTargetResolver) resolveServicePodList(
	ctx context.Context,
	target Identity,
	service corev1.Service,
	remotePort uint16,
) (ResolvedTarget, error) {
	if len(service.Spec.Selector) == 0 {
		return ResolvedTarget{}, fmt.Errorf("%w: Service has no selector", ErrNoEligiblePod)
	}
	selector := labels.SelectorFromSet(service.Spec.Selector).String()
	phaseSelector := fields.AndSelectors(
		fields.OneTermNotEqualSelector("status.phase", string(corev1.PodSucceeded)),
		fields.OneTermNotEqualSelector("status.phase", string(corev1.PodFailed)),
	).String()
	var selected *corev1.Pod
	continuation := ""
	seenContinuations := make(map[string]struct{})
	for {
		pods, err := r.Core.Pods(target.Namespace).List(ctx, metav1.ListOptions{
			LabelSelector: selector,
			FieldSelector: phaseSelector,
			Limit:         servicePodListPageSize,
			Continue:      continuation,
		})
		if err != nil {
			return ResolvedTarget{}, err
		}
		for index := range pods.Items {
			pod := &pods.Items[index]
			if pod.DeletionTimestamp != nil || pod.Status.Phase == corev1.PodFailed ||
				pod.Status.Phase == corev1.PodSucceeded || !podReady(pod.Status.Conditions) {
				continue
			}
			if selected == nil || strings.Compare(string(pod.UID), string(selected.UID)) < 0 {
				copy := pod.DeepCopy()
				selected = copy
			}
		}
		next := pods.GetContinue()
		if next == "" {
			break
		}
		if _, duplicate := seenContinuations[next]; duplicate {
			return ResolvedTarget{}, errors.New("Kubernetes Pod pagination repeated a continuation token")
		}
		seenContinuations[next] = struct{}{}
		continuation = next
	}
	if selected == nil {
		return ResolvedTarget{}, ErrNoEligiblePod
	}
	identity := Identity{
		SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: selected.Namespace,
		Name: selected.Name, UID: selected.UID,
	}
	resolvedPort, err := serviceTargetPort(service.Spec.Ports, *selected, remotePort)
	if err != nil {
		return ResolvedTarget{}, err
	}
	return ResolvedTarget{Pod: identity, RemotePort: resolvedPort}, nil
}

func podReady(conditions []corev1.PodCondition) bool {
	for _, condition := range conditions {
		if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

func serviceTargetPort(
	ports []corev1.ServicePort,
	selected corev1.Pod,
	remotePort uint16,
) (uint16, error) {
	for _, port := range ports {
		if port.Port != int32(remotePort) {
			continue
		}
		if port.TargetPort.IntVal > 0 {
			return uint16(port.TargetPort.IntVal), nil
		}
		if port.TargetPort.StrVal == "" {
			return remotePort, nil
		}
		for _, container := range selected.Spec.Containers {
			for _, containerPort := range container.Ports {
				if containerPort.Name == port.TargetPort.StrVal && containerPort.ContainerPort > 0 {
					return uint16(containerPort.ContainerPort), nil
				}
			}
		}
		return 0, fmt.Errorf("%w: selected Pod does not declare named target port %q", ErrInvalidRequest, port.TargetPort.StrVal)
	}
	// A manually entered port may address the Pod directly even when it is not
	// declared by the Service.
	return remotePort, nil
}
