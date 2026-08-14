package portforward

import (
	"context"
	"errors"
	"fmt"
	"sort"
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
		pods, err := r.Core.Pods(target.Namespace).List(ctx, metav1.ListOptions{
			LabelSelector: labels.SelectorFromSet(service.Spec.Selector).String(),
			FieldSelector: fields.OneTermNotEqualSelector("status.phase", "Succeeded").String(),
		})
		if err != nil {
			return ResolvedTarget{}, err
		}
		eligible := make([]Identity, 0, len(pods.Items))
		for _, pod := range pods.Items {
			if pod.DeletionTimestamp != nil || pod.Status.Phase == "Failed" || pod.Status.Phase == "Succeeded" ||
				!podReady(pod.Status.Conditions) {
				continue
			}
			eligible = append(eligible, Identity{
				SessionID: target.SessionID, Version: "v1", Resource: "pods", Namespace: pod.Namespace,
				Name: pod.Name, UID: pod.UID,
			})
		}
		if len(eligible) == 0 {
			return ResolvedTarget{}, ErrNoEligiblePod
		}
		sort.Slice(eligible, func(i, j int) bool {
			return strings.Compare(string(eligible[i].UID), string(eligible[j].UID)) < 0
		})
		resolvedPort, err := serviceTargetPort(service.Spec.Ports, pods.Items, eligible[0], remotePort)
		if err != nil {
			return ResolvedTarget{}, err
		}
		return ResolvedTarget{Pod: eligible[0], RemotePort: resolvedPort}, nil
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
	pods []corev1.Pod,
	selected Identity,
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
		for _, pod := range pods {
			if pod.UID != selected.UID {
				continue
			}
			for _, container := range pod.Spec.Containers {
				for _, containerPort := range container.Ports {
					if containerPort.Name == port.TargetPort.StrVal && containerPort.ContainerPort > 0 {
						return uint16(containerPort.ContainerPort), nil
					}
				}
			}
		}
		return 0, fmt.Errorf("%w: selected Pod does not declare named target port %q", ErrInvalidRequest, port.TargetPort.StrVal)
	}
	// A manually entered port may address the Pod directly even when it is not
	// declared by the Service.
	return remotePort, nil
}
