package logs

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	DefaultMaxResolvedPods      = 128
	defaultResolutionPageSize   = 500
	defaultMaxResolutionObjects = 10_000
	defaultMaxResolutionCalls   = 512
	defaultMaxCronJobOwnedJobs  = 128
)

var (
	ErrWorkloadResolutionUnavailable = errors.New("workload log resolution is unavailable")
	ErrUnsupportedLogResource        = errors.New("resource does not support logs")
	ErrResolutionScanLimit           = errors.New("workload log resolution scan limit exceeded")
)

// PodInventory is the immutable, UID-pinned Pod and regular-container
// inventory returned to the configuration sheet.
type PodInventory struct {
	Identity   Identity
	Containers []string
}

type SourceResolution struct {
	Pods                   []PodInventory
	StaticWorkloadSnapshot bool
}

type WorkloadSourceResolver interface {
	Resolve(context.Context, string, []Identity, int) (SourceResolution, error)
}

type ClusterWorkloadSourceResolver struct {
	Sessions *cluster.SessionRegistry
}

type UnsupportedLogResourceError struct {
	Identity Identity
}

func (e *UnsupportedLogResourceError) Error() string {
	return fmt.Sprintf("%s/%s does not support Pod logs", e.Identity.Resource, e.Identity.Name)
}

func (e *UnsupportedLogResourceError) Unwrap() error { return ErrUnsupportedLogResource }

// ResolutionUIDMismatchError prevents a stale table row from resolving either
// a replacement workload or a same-name replacement Pod.
type ResolutionUIDMismatchError struct {
	Identity Identity
	Actual   string
}

func (e *ResolutionUIDMismatchError) Error() string {
	return fmt.Sprintf(
		"%s %s/%s was replaced (expected UID %s, found %s)",
		e.Identity.Resource, e.Identity.Namespace, e.Identity.Name, e.Identity.UID, e.Actual,
	)
}

type TooManyResolvedPodsError struct {
	Limit int
}

func (e *TooManyResolvedPodsError) Error() string {
	return fmt.Sprintf("the selected resources resolve to more than %d Pods", e.Limit)
}

type ResolutionScanLimitError struct {
	Resource string
	Limit    int
}

func (e *ResolutionScanLimitError) Error() string {
	return fmt.Sprintf("examining %s exceeded the bounded scan limit of %d objects", e.Resource, e.Limit)
}

func (e *ResolutionScanLimitError) Unwrap() error { return ErrResolutionScanLimit }

type ResolutionRequestLimitError struct {
	Limit int
}

func (e *ResolutionRequestLimitError) Error() string {
	return fmt.Sprintf("workload log resolution exceeded its request-wide limit of %d Kubernetes API calls", e.Limit)
}

func (e *ResolutionRequestLimitError) Unwrap() error { return ErrResolutionScanLimit }

type sourceResolutionClients struct {
	sessionID       string
	core            coreclient.CoreV1Interface
	dynamic         dynamic.Interface
	maxPods         int
	pods            map[types.UID]PodInventory
	objectsExamined int
	apiCalls        int
}

func (r ClusterWorkloadSourceResolver) Resolve(
	ctx context.Context,
	sessionID string,
	identities []Identity,
	maxPods int,
) (SourceResolution, error) {
	if r.Sessions == nil {
		return SourceResolution{}, ErrSessionNotFound
	}
	if maxPods <= 0 {
		maxPods = DefaultMaxResolvedPods
	}
	session, lease, ok := r.Sessions.Acquire(sessionID)
	if !ok {
		return SourceResolution{}, ErrSessionNotFound
	}
	defer lease.Release()
	if session.Core() == nil || session.Dynamic() == nil {
		return SourceResolution{}, ErrWorkloadResolutionUnavailable
	}
	clients := sourceResolutionClients{
		sessionID: sessionID, core: session.Core(), dynamic: session.Dynamic(), maxPods: maxPods,
		pods: make(map[types.UID]PodInventory),
	}
	staticSnapshot := false
	for _, identity := range identities {
		if err := ctx.Err(); err != nil {
			return SourceResolution{}, err
		}
		if identity.SessionID != sessionID {
			return SourceResolution{}, fmt.Errorf("%w: resource belongs to a different cluster session", ErrInvalidRequest)
		}
		isWorkload, err := clients.resolveOne(ctx, identity)
		if err != nil {
			return SourceResolution{}, err
		}
		staticSnapshot = staticSnapshot || isWorkload
	}
	result := SourceResolution{
		Pods:                   make([]PodInventory, 0, len(clients.pods)),
		StaticWorkloadSnapshot: staticSnapshot,
	}
	for _, pod := range clients.pods {
		result.Pods = append(result.Pods, pod)
	}
	sort.Slice(result.Pods, func(i, j int) bool {
		left, right := result.Pods[i].Identity, result.Pods[j].Identity
		if left.Namespace != right.Namespace {
			return left.Namespace < right.Namespace
		}
		if left.Name != right.Name {
			return left.Name < right.Name
		}
		return left.UID < right.UID
	})
	return result, nil
}

func (c *sourceResolutionClients) resolveOne(ctx context.Context, identity Identity) (bool, error) {
	switch {
	case identity.Group == "" && identity.Version == "v1" && identity.Resource == "pods":
		if err := c.beginAPICall(); err != nil {
			return false, err
		}
		pod, err := c.core.Pods(identity.Namespace).Get(ctx, identity.Name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		if err := c.observeObjects("Pods", 1); err != nil {
			return false, err
		}
		if err := validateResolutionUID(identity, pod.UID); err != nil {
			return false, err
		}
		return false, c.addPod(identityFromPod(identity.SessionID, pod))
	case identity.Group == "apps" && identity.Version == "v1" && identity.Resource == "deployments":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		var deployment appsv1.Deployment
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(value.Object, &deployment); err != nil {
			return true, fmt.Errorf("decode Deployment: %w", err)
		}
		selector, err := selectorFromLabelSelector(deployment.Spec.Selector)
		if err != nil {
			return true, err
		}
		replicaSets, err := c.listControlledObjects(
			ctx, schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "replicasets"},
			identity.Namespace, selector, types.UID(identity.UID),
		)
		if err != nil {
			return true, err
		}
		owners := make(map[types.UID]struct{}, len(replicaSets))
		for _, replicaSet := range replicaSets {
			owners[replicaSet.GetUID()] = struct{}{}
		}
		return true, c.listPods(ctx, identity.Namespace, selector, owners)
	case identity.Group == "apps" && identity.Version == "v1" && identity.Resource == "replicasets":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		var replicaSet appsv1.ReplicaSet
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(value.Object, &replicaSet); err != nil {
			return true, fmt.Errorf("decode ReplicaSet: %w", err)
		}
		selector, err := selectorFromLabelSelector(replicaSet.Spec.Selector)
		if err != nil {
			return true, err
		}
		return true, c.listPods(ctx, identity.Namespace, selector, uidSet(value.GetUID()))
	case identity.Group == "apps" && identity.Version == "v1" && identity.Resource == "statefulsets":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		var statefulSet appsv1.StatefulSet
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(value.Object, &statefulSet); err != nil {
			return true, fmt.Errorf("decode StatefulSet: %w", err)
		}
		selector, err := selectorFromLabelSelector(statefulSet.Spec.Selector)
		if err != nil {
			return true, err
		}
		return true, c.listPods(ctx, identity.Namespace, selector, uidSet(value.GetUID()))
	case identity.Group == "apps" && identity.Version == "v1" && identity.Resource == "daemonsets":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		var daemonSet appsv1.DaemonSet
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(value.Object, &daemonSet); err != nil {
			return true, fmt.Errorf("decode DaemonSet: %w", err)
		}
		selector, err := selectorFromLabelSelector(daemonSet.Spec.Selector)
		if err != nil {
			return true, err
		}
		return true, c.listPods(ctx, identity.Namespace, selector, uidSet(value.GetUID()))
	case identity.Group == "batch" && identity.Version == "v1" && identity.Resource == "jobs":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		return true, c.resolveJob(ctx, identity.Namespace, value)
	case identity.Group == "batch" && identity.Version == "v1" && identity.Resource == "cronjobs":
		value, err := c.getController(ctx, identity)
		if err != nil {
			return true, err
		}
		jobs, err := c.listControlledObjects(
			ctx, schema.GroupVersionResource{Group: "batch", Version: "v1", Resource: "jobs"},
			identity.Namespace, labels.Everything(), value.GetUID(),
		)
		if err != nil {
			return true, err
		}
		if len(jobs) > defaultMaxCronJobOwnedJobs {
			return true, &ResolutionScanLimitError{Resource: "Jobs owned by the CronJob", Limit: defaultMaxCronJobOwnedJobs}
		}
		owners := make(map[types.UID]struct{}, len(jobs))
		for index := range jobs {
			owners[jobs[index].GetUID()] = struct{}{}
		}
		// One bounded namespace Pod list is preferable to one list per retained
		// Job, and the controller-owner UID filter still validates the second
		// CronJob -> Job -> Pod hop exactly.
		return true, c.listPods(ctx, identity.Namespace, labels.Everything(), owners)
	default:
		return false, &UnsupportedLogResourceError{Identity: identity}
	}
}

func (c *sourceResolutionClients) getController(
	ctx context.Context,
	identity Identity,
) (*unstructured.Unstructured, error) {
	gvr := schema.GroupVersionResource{Group: identity.Group, Version: identity.Version, Resource: identity.Resource}
	if err := c.beginAPICall(); err != nil {
		return nil, err
	}
	value, err := c.dynamic.Resource(gvr).Namespace(identity.Namespace).Get(ctx, identity.Name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	if err := c.observeObjects(identity.Resource, 1); err != nil {
		return nil, err
	}
	if err := validateResolutionUID(identity, value.GetUID()); err != nil {
		return nil, err
	}
	return value, nil
}

func (c *sourceResolutionClients) resolveJob(
	ctx context.Context,
	namespace string,
	value *unstructured.Unstructured,
) error {
	var job batchv1.Job
	if err := runtime.DefaultUnstructuredConverter.FromUnstructured(value.Object, &job); err != nil {
		return fmt.Errorf("decode Job: %w", err)
	}
	selector := labels.Everything()
	if job.Spec.Selector != nil {
		var err error
		selector, err = selectorFromLabelSelector(job.Spec.Selector)
		if err != nil {
			return fmt.Errorf("Job %s has no resolvable Pod selector: %w", job.Name, err)
		}
	}
	return c.listPods(ctx, namespace, selector, uidSet(value.GetUID()))
}

func (c *sourceResolutionClients) listControlledObjects(
	ctx context.Context,
	gvr schema.GroupVersionResource,
	namespace string,
	selector labels.Selector,
	ownerUID types.UID,
) ([]unstructured.Unstructured, error) {
	var result []unstructured.Unstructured
	var continueToken string
	for {
		if err := c.beginAPICall(); err != nil {
			return nil, err
		}
		list, err := c.dynamic.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: selector.String(), Limit: defaultResolutionPageSize, Continue: continueToken,
		})
		if err != nil {
			return nil, err
		}
		if err := c.observeObjects(gvr.Resource, len(list.Items)); err != nil {
			return nil, err
		}
		for index := range list.Items {
			if controllerUID(&list.Items[index]) == ownerUID {
				result = append(result, list.Items[index])
			}
		}
		continueToken = list.GetContinue()
		if continueToken == "" {
			return result, nil
		}
	}
}

func (c *sourceResolutionClients) listPods(
	ctx context.Context,
	namespace string,
	selector labels.Selector,
	ownerUIDs map[types.UID]struct{},
) error {
	if len(ownerUIDs) == 0 {
		return nil
	}
	var continueToken string
	for {
		if err := c.beginAPICall(); err != nil {
			return err
		}
		list, err := c.core.Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: selector.String(), Limit: defaultResolutionPageSize, Continue: continueToken,
		})
		if err != nil {
			return err
		}
		if err := c.observeObjects("Pods", len(list.Items)); err != nil {
			return err
		}
		for index := range list.Items {
			pod := &list.Items[index]
			if _, controlled := ownerUIDs[controllerUID(pod)]; !controlled {
				continue
			}
			if err := c.addPod(identityFromPod(c.sessionID, pod)); err != nil {
				return err
			}
		}
		continueToken = list.GetContinue()
		if continueToken == "" {
			return nil
		}
	}
}

func (c *sourceResolutionClients) beginAPICall() error {
	if c.apiCalls >= defaultMaxResolutionCalls {
		return &ResolutionRequestLimitError{Limit: defaultMaxResolutionCalls}
	}
	c.apiCalls++
	return nil
}

func (c *sourceResolutionClients) observeObjects(resource string, count int) error {
	if count < 0 || count > defaultMaxResolutionObjects-c.objectsExamined {
		return &ResolutionScanLimitError{Resource: resource, Limit: defaultMaxResolutionObjects}
	}
	c.objectsExamined += count
	return nil
}

func (c *sourceResolutionClients) addPod(pod PodInventory) error {
	uid := types.UID(pod.Identity.UID)
	if _, exists := c.pods[uid]; exists {
		return nil
	}
	if len(c.pods) >= c.maxPods {
		return &TooManyResolvedPodsError{Limit: c.maxPods}
	}
	c.pods[uid] = pod
	return nil
}

func identityFromPod(sessionID string, pod *corev1.Pod) PodInventory {
	containers := make([]string, 0, len(pod.Spec.Containers))
	for _, container := range pod.Spec.Containers {
		if container.Name != "" {
			containers = append(containers, container.Name)
		}
	}
	sort.Strings(containers)
	return PodInventory{
		Identity: Identity{
			SessionID: sessionID, Version: "v1", Resource: "pods", Namespace: pod.Namespace,
			Name: pod.Name, UID: string(pod.UID),
		},
		Containers: containers,
	}
}

func validateResolutionUID(identity Identity, actual types.UID) error {
	if string(actual) == identity.UID {
		return nil
	}
	return &ResolutionUIDMismatchError{Identity: identity, Actual: string(actual)}
}

func selectorFromLabelSelector(value *metav1.LabelSelector) (labels.Selector, error) {
	if value == nil {
		return nil, errors.New("selector is absent")
	}
	selector, err := metav1.LabelSelectorAsSelector(value)
	if err != nil {
		return nil, err
	}
	if selector.Empty() {
		return nil, errors.New("selector is empty")
	}
	return selector, nil
}

func uidSet(values ...types.UID) map[types.UID]struct{} {
	result := make(map[types.UID]struct{}, len(values))
	for _, value := range values {
		if value != "" {
			result[value] = struct{}{}
		}
	}
	return result
}

func controllerUID(value metav1.Object) types.UID {
	if value == nil {
		return ""
	}
	for _, owner := range value.GetOwnerReferences() {
		if owner.Controller != nil && *owner.Controller {
			return owner.UID
		}
	}
	return ""
}
