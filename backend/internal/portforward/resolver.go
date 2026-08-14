package portforward

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
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
	resolver := ClientGoTargetResolver{Core: session.Core()}
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
	Core v1.CoreV1Interface
}

const servicePodListPageSize int64 = 500

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
			return ResolvedTarget{}, fmt.Errorf("Service was recreated: expected UID %q, found %q", target.UID, service.UID)
		}
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
	default:
		return ResolvedTarget{}, fmt.Errorf("%w: target must be a Pod or Service", ErrInvalidRequest)
	}
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
