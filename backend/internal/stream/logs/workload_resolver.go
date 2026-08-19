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
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/selection"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/metadata"
)

const (
	DefaultMaxResolvedPods      = 128
	defaultResolutionPageSize   = 500
	defaultMaxResolutionObjects = 10_000
	defaultMaxResolutionCalls   = 512
	defaultMaxCronJobOwnedJobs  = 128
	legacyJobControllerUIDLabel = "controller-uid"
)

var (
	ErrWorkloadResolutionUnavailable = errors.New("workload log resolution is unavailable")
	ErrUnsupportedLogResource        = errors.New("resource does not support logs")
	ErrResolutionScanLimit           = errors.New("workload log resolution scan limit exceeded")
	ErrResolutionPagination          = errors.New("workload log resolution pagination did not advance")
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
	metadata        metadata.Interface
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
	if session.Core() == nil || session.Dynamic() == nil || session.Metadata() == nil {
		return SourceResolution{}, ErrWorkloadResolutionUnavailable
	}
	clients := sourceResolutionClients{
		sessionID: sessionID, core: session.Core(), dynamic: session.Dynamic(), metadata: session.Metadata(), maxPods: maxPods,
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
		return true, c.resolveCronJob(ctx, identity.Namespace, value)
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
	selector, controllerLabel, err := podSelectorForJob(&job)
	if err != nil {
		return err
	}
	owners := uidSet(value.GetUID())
	if controllerLabel != "" {
		selector, err = controllerUIDSelector(controllerLabel, owners)
		if err != nil {
			return fmt.Errorf("build Job %s Pod selector: %w", job.Name, err)
		}
	}
	return c.listPods(ctx, namespace, selector, owners)
}

func (c *sourceResolutionClients) resolveCronJob(
	ctx context.Context,
	namespace string,
	value *unstructured.Unstructured,
) error {
	jobs, err := c.listControlledObjects(
		ctx, schema.GroupVersionResource{Group: "batch", Version: "v1", Resource: "jobs"},
		namespace, labels.Everything(), value.GetUID(),
	)
	if err != nil {
		return err
	}
	if len(jobs) > defaultMaxCronJobOwnedJobs {
		return &ResolutionScanLimitError{Resource: "Jobs owned by the CronJob", Limit: defaultMaxCronJobOwnedJobs}
	}

	// Owner references have no portable server-side selector, so the namespace
	// Job scan above is metadata-only. Fetch full objects only for exact owned
	// UIDs so manual Job selectors retain their behavior without transferring
	// every unrelated Job spec in the namespace.
	controllerOwners := make(map[string]map[types.UID]struct{})
	selectorGroups := make(map[string]*podSelectorGroup)
	for index := range jobs {
		jobMeta := &jobs[index]
		jobValue, getErr := c.listControllerByName(ctx, Identity{
			SessionID: c.sessionID, Group: "batch", Version: "v1", Resource: "jobs",
			Namespace: namespace, Name: jobMeta.GetName(), UID: string(jobMeta.GetUID()),
		})
		if getErr != nil {
			return getErr
		}
		var job batchv1.Job
		if err := runtime.DefaultUnstructuredConverter.FromUnstructured(jobValue.Object, &job); err != nil {
			return fmt.Errorf("decode Job %s: %w", jobMeta.GetName(), err)
		}
		selector, controllerLabel, err := podSelectorForJob(&job)
		if err != nil {
			return err
		}
		if controllerLabel != "" {
			owners := controllerOwners[controllerLabel]
			if owners == nil {
				owners = make(map[types.UID]struct{})
				controllerOwners[controllerLabel] = owners
			}
			owners[jobValue.GetUID()] = struct{}{}
			continue
		}
		key := selector.String()
		group := selectorGroups[key]
		if group == nil {
			group = &podSelectorGroup{selector: selector, ownerUIDs: make(map[types.UID]struct{})}
			selectorGroups[key] = group
		}
		group.ownerUIDs[jobValue.GetUID()] = struct{}{}
	}

	for labelKey, owners := range controllerOwners {
		selector, err := controllerUIDSelector(labelKey, owners)
		if err != nil {
			return fmt.Errorf("build CronJob Pod selector: %w", err)
		}
		key := selector.String()
		group := selectorGroups[key]
		if group == nil {
			group = &podSelectorGroup{selector: selector, ownerUIDs: make(map[types.UID]struct{})}
			selectorGroups[key] = group
		}
		for uid := range owners {
			group.ownerUIDs[uid] = struct{}{}
		}
	}
	groups := make([]*podSelectorGroup, 0, len(selectorGroups))
	for _, group := range selectorGroups {
		groups = append(groups, group)
	}
	sort.Slice(groups, func(i, j int) bool {
		return groups[i].selector.String() < groups[j].selector.String()
	})
	for _, group := range groups {
		if err := c.listPods(ctx, namespace, group.selector, group.ownerUIDs); err != nil {
			return err
		}
	}
	return nil
}

// listControllerByName retains the LIST permission required by the existing
// owner traversal while requesting only the one full object whose selector is
// needed. Requiring GET on every owned Job would unnecessarily expand RBAC for
// CronJob log resolution.
func (c *sourceResolutionClients) listControllerByName(
	ctx context.Context,
	identity Identity,
) (*unstructured.Unstructured, error) {
	gvr := schema.GroupVersionResource{Group: identity.Group, Version: identity.Version, Resource: identity.Resource}
	if err := c.beginAPICall(); err != nil {
		return nil, err
	}
	list, err := c.dynamic.Resource(gvr).Namespace(identity.Namespace).List(ctx, metav1.ListOptions{
		FieldSelector: fields.OneTermEqualSelector("metadata.name", identity.Name).String(), Limit: 1,
	})
	if err != nil {
		return nil, err
	}
	if err := c.observeObjects(identity.Resource, len(list.Items)); err != nil {
		return nil, err
	}
	if len(list.Items) == 0 {
		return nil, apierrors.NewNotFound(gvr.GroupResource(), identity.Name)
	}
	value := &list.Items[0]
	if err := validateResolutionUID(identity, value.GetUID()); err != nil {
		return nil, err
	}
	return value, nil
}

type podSelectorGroup struct {
	selector  labels.Selector
	ownerUIDs map[types.UID]struct{}
}

func podSelectorForJob(job *batchv1.Job) (labels.Selector, string, error) {
	if job == nil {
		return nil, "", errors.New("Job is absent")
	}
	if job.Spec.Selector == nil {
		// The Kubernetes API normally defaults this selector. Retain a narrow
		// fallback for synthetic or non-defaulted representations instead of
		// listing every Pod in the namespace.
		return nil, batchv1.ControllerUidLabel, nil
	}
	selector, err := selectorFromLabelSelector(job.Spec.Selector)
	if err != nil {
		return nil, "", fmt.Errorf("Job %s has no resolvable Pod selector: %w", job.Name, err)
	}
	if key := exactJobControllerUIDLabel(job.Spec.Selector, job.UID); key != "" {
		return nil, key, nil
	}
	return selector, "", nil
}

func exactJobControllerUIDLabel(selector *metav1.LabelSelector, uid types.UID) string {
	if selector == nil || len(selector.MatchExpressions) != 0 || len(selector.MatchLabels) != 1 {
		return ""
	}
	for _, key := range []string{batchv1.ControllerUidLabel, legacyJobControllerUIDLabel} {
		if selector.MatchLabels[key] == string(uid) {
			return key
		}
	}
	return ""
}

func controllerUIDSelector(key string, ownerUIDs map[types.UID]struct{}) (labels.Selector, error) {
	values := make([]string, 0, len(ownerUIDs))
	for uid := range ownerUIDs {
		if uid != "" {
			values = append(values, string(uid))
		}
	}
	sort.Strings(values)
	requirement, err := labels.NewRequirement(key, selection.In, values)
	if err != nil {
		return nil, err
	}
	return labels.NewSelector().Add(*requirement), nil
}

func (c *sourceResolutionClients) listControlledObjects(
	ctx context.Context,
	gvr schema.GroupVersionResource,
	namespace string,
	selector labels.Selector,
	ownerUID types.UID,
) ([]metav1.PartialObjectMetadata, error) {
	var result []metav1.PartialObjectMetadata
	var continueToken string
	seenContinueTokens := make(map[string]struct{})
	for {
		if err := c.beginAPICall(); err != nil {
			return nil, err
		}
		list, err := c.metadata.Resource(gvr).Namespace(namespace).List(ctx, metav1.ListOptions{
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
		nextContinueToken, err := resolutionContinueToken(
			gvr.Resource, list.GetContinue(), seenContinueTokens,
		)
		if err != nil {
			return nil, err
		}
		if nextContinueToken == "" {
			return result, nil
		}
		continueToken = nextContinueToken
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
	seenContinueTokens := make(map[string]struct{})
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
		nextContinueToken, err := resolutionContinueToken(
			"Pods", list.GetContinue(), seenContinueTokens,
		)
		if err != nil {
			return err
		}
		if nextContinueToken == "" {
			return nil
		}
		continueToken = nextContinueToken
	}
}

func resolutionContinueToken(
	resource string,
	next string,
	seen map[string]struct{},
) (string, error) {
	if next == "" {
		return "", nil
	}
	if _, repeated := seen[next]; repeated {
		return "", fmt.Errorf("%w: %s repeated continue token %q", ErrResolutionPagination, resource, next)
	}
	seen[next] = struct{}{}
	return next, nil
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
