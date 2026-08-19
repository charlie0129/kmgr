package portforward

import (
	"context"
	"errors"
	"fmt"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	"github.com/charlie0129/kmgr/backend/internal/podidentity"
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
	if session.Core() == nil || session.Metadata() == nil ||
		session.Core().RESTClient() == nil || session.RESTConfig() == nil {
		lease.Release()
		return Session{}, errors.New("Kubernetes port-forward client is unavailable")
	}
	podUIDs := podidentity.MetadataGetter{Client: session.Metadata()}
	resolver := ClientGoTargetResolver{Core: session.Core(), Dynamic: session.Dynamic(), PodUIDs: podUIDs}
	return Session{
		ContextName: session.Context().Name,
		Resolver:    resolver,
		Forwarder: ClientGoForwarder{
			Config: session.RESTConfig(), RESTClient: session.Core().RESTClient(), PodUIDs: podUIDs,
		},
		Release: lease.Release,
	}, nil
}

type ClientGoTargetResolver struct {
	Core    v1.CoreV1Interface
	Dynamic dynamic.Interface
	PodUIDs podidentity.Getter
}

const (
	serviceEndpointSliceListPageSize  int64 = 500
	servicePodListPageSize            int64 = 500
	serviceEndpointPodValidationLimit       = 8
)

var endpointSliceResource = schema.GroupVersionResource{
	Group: "discovery.k8s.io", Version: "v1", Resource: "endpointslices",
}

var errEndpointPodAccessFallback = errors.New("EndpointSlice Pod access requires selector fallback")

func (r ClientGoTargetResolver) Resolve(ctx context.Context, target Identity, remotePort uint16) (ResolvedTarget, error) {
	if r.Core == nil {
		return ResolvedTarget{}, errors.New("Kubernetes Core client is unavailable")
	}
	switch {
	case target.IsPod():
		if r.PodUIDs == nil {
			return ResolvedTarget{}, errors.New("Kubernetes Pod metadata client is unavailable")
		}
		uid, err := r.PodUIDs.PodUID(ctx, target.Namespace, target.Name)
		if err != nil {
			return ResolvedTarget{}, err
		}
		if uid != target.UID {
			return ResolvedTarget{}, fmt.Errorf("%w: expected UID %q, found %q", ErrPodRecreated, target.UID, uid)
		}
		return ResolvedTarget{Pod: Identity{
			SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: target.Namespace,
			Name: target.Name, UID: uid,
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
	name string
	uid  types.UID
}

// resolveServiceEndpointSlice follows the stable order returned by paginated
// EndpointSlice LISTs and stops at the first viable Pod. Exact Pod validation
// is capped so a stale endpoint index cannot turn one port-forward into an
// unbounded sequence of GETs. The caller retains the label-selected Pod LIST
// compatibility fallback for unavailable or stale EndpointSlices and services
// whose endpoints do not target Pods.
func (r ClientGoTargetResolver) resolveServiceEndpointSlice(
	ctx context.Context,
	target Identity,
	service corev1.Service,
	remotePort uint16,
) (ResolvedTarget, bool, error) {
	continuation := ""
	seenContinuations := make(map[string]struct{})
	seenCandidates := make(map[types.UID]struct{}, serviceEndpointPodValidationLimit)
	validatedCandidates := 0
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
				if _, duplicate := seenCandidates[ref.UID]; duplicate {
					continue
				}
				if validatedCandidates == serviceEndpointPodValidationLimit {
					return ResolvedTarget{}, false, nil
				}
				seenCandidates[ref.UID] = struct{}{}
				validatedCandidates++
				resolved, viable, err := r.validateEndpointPod(
					ctx,
					target,
					service,
					endpointPodCandidate{name: ref.Name, uid: ref.UID},
					remotePort,
				)
				if err != nil {
					if errors.Is(err, errEndpointPodAccessFallback) {
						return ResolvedTarget{}, false, nil
					}
					return ResolvedTarget{}, false, err
				}
				if viable {
					return resolved, true, nil
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
	return ResolvedTarget{}, false, nil
}

func (r ClientGoTargetResolver) validateEndpointPod(
	ctx context.Context,
	target Identity,
	service corev1.Service,
	candidate endpointPodCandidate,
	remotePort uint16,
) (ResolvedTarget, bool, error) {
	pod, err := r.Core.Pods(target.Namespace).Get(ctx, candidate.name, metav1.GetOptions{})
	if err != nil {
		if apierrors.IsForbidden(err) {
			return ResolvedTarget{}, false, errEndpointPodAccessFallback
		}
		if apierrors.IsNotFound(err) {
			return ResolvedTarget{}, false, nil
		}
		return ResolvedTarget{}, false, fmt.Errorf("get EndpointSlice Pod: %w", err)
	}
	if pod.UID != candidate.uid || pod.DeletionTimestamp != nil ||
		pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodSucceeded ||
		!podReady(pod.Status.Conditions) {
		return ResolvedTarget{}, false, nil
	}
	resolvedPort, err := serviceTargetPort(service.Spec.Ports, *pod, remotePort)
	if err != nil {
		if errors.Is(err, ErrInvalidRequest) {
			return ResolvedTarget{}, false, nil
		}
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
	var targetPortErr error
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
			resolvedPort, err := serviceTargetPort(service.Spec.Ports, *pod, remotePort)
			if err != nil {
				targetPortErr = err
				continue
			}
			return ResolvedTarget{
				Pod: Identity{
					SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: pod.Namespace,
					Name: pod.Name, UID: pod.UID,
				},
				RemotePort: resolvedPort,
			}, nil
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
	if targetPortErr != nil {
		return ResolvedTarget{}, targetPortErr
	}
	return ResolvedTarget{}, ErrNoEligiblePod
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
