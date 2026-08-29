// Package object implements fresh, UID-authoritative Kubernetes object reads.
// Table views retain raw objects in Go, while this package exposes display YAML
// (with metadata.managedFields omitted) or sensitive key/value bytes only after
// an explicit detail request.
package object

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	k8sruntime "k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"sigs.k8s.io/yaml"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
)

var (
	ErrSessionNotFound       = errors.New("cluster session was not found")
	ErrInvalidIdentity       = errors.New("resource identity is incomplete")
	ErrUnsupportedDataObject = errors.New("resource does not have an editable key/value data surface")
)

type Identity struct {
	SessionID string
	Group     string
	Version   string
	Resource  string
	Namespace string
	Name      string
	UID       string
}

func (i Identity) GVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: i.Group, Version: i.Version, Resource: i.Resource}
}

func (i Identity) Validate() error {
	if strings.TrimSpace(i.SessionID) == "" || strings.TrimSpace(i.Version) == "" ||
		strings.TrimSpace(i.Resource) == "" || strings.TrimSpace(i.Name) == "" || strings.TrimSpace(i.UID) == "" {
		return ErrInvalidIdentity
	}
	return nil
}

// IdentityChangedError prevents a stale namespace/name selection from silently
// opening or mutating a newly recreated Kubernetes object.
type IdentityChangedError struct {
	ExpectedUID string
	ActualUID   string
	Namespace   string
	Name        string
}

func (e *IdentityChangedError) Error() string {
	return fmt.Sprintf(
		"resource %s/%s was recreated (expected UID %q, found %q)",
		e.Namespace, e.Name, e.ExpectedUID, e.ActualUID,
	)
}

// Resolver narrows cluster authority to the one operation a fresh object read
// needs. It makes identity and sensitive-data behavior testable with fake
// dynamic clients.
type Resolver interface {
	Resource(sessionID string, gvr schema.GroupVersionResource, namespace string) (dynamic.ResourceInterface, error)
}

// ContextNameResolver is an optional Resolver capability used only to enrich
// display-safe structured errors with the human kubeconfig context name. The
// cluster session ID remains the authority boundary; callers must not treat
// the context name as an identifier.
type ContextNameResolver interface {
	ContextName(sessionID string) (string, bool)
}

type ClusterResolver struct {
	Sessions *cluster.SessionRegistry
}

func (r ClusterResolver) Resource(
	sessionID string,
	gvr schema.GroupVersionResource,
	namespace string,
) (dynamic.ResourceInterface, error) {
	if r.Sessions == nil {
		return nil, ErrSessionNotFound
	}
	session, ok := r.Sessions.Get(sessionID)
	if !ok {
		return nil, ErrSessionNotFound
	}
	resource := session.Dynamic().Resource(gvr)
	if namespace == "" {
		return resource, nil
	}
	return resource.Namespace(namespace), nil
}

func (r ClusterResolver) ContextName(sessionID string) (string, bool) {
	if r.Sessions == nil {
		return "", false
	}
	session, ok := r.Sessions.Get(sessionID)
	if !ok || session.Context().Name == "" {
		return "", false
	}
	return session.Context().Name, true
}

type Reader struct {
	resolver Resolver
}

func NewReader(resolver Resolver) (*Reader, error) {
	if resolver == nil {
		return nil, errors.New("object resolver must not be nil")
	}
	return &Reader{resolver: resolver}, nil
}

// ContextName returns display context for a currently live cluster session
// when the configured resolver can provide it. Test and alternate resolvers
// are not required to implement this optional presentation capability.
func (r *Reader) ContextName(sessionID string) (string, bool) {
	if r == nil || r.resolver == nil {
		return "", false
	}
	resolver, ok := r.resolver.(ContextNameResolver)
	if !ok {
		return "", false
	}
	return resolver.ContextName(sessionID)
}

// Resource resolves the exact namespaced or cluster-scoped dynamic resource
// selected by identity. Callers still need Get when they require a fresh UID
// check; this narrow seam exists for operations such as UID-preconditioned
// deletes and subresource updates.
func (r *Reader) Resource(identity Identity) (dynamic.ResourceInterface, error) {
	if err := identity.Validate(); err != nil {
		return nil, err
	}
	return r.resolver.Resource(identity.SessionID, identity.GVR(), identity.Namespace)
}

// Get always performs an API GET. Cached command-palette or view identities
// therefore cannot enable authoritative details or mutations without refresh.
func (r *Reader) Get(ctx context.Context, identity Identity) (*unstructured.Unstructured, error) {
	resource, err := r.Resource(identity)
	if err != nil {
		return nil, err
	}
	value, err := resource.Get(ctx, identity.Name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	if err := validateObjectUID(value, identity); err != nil {
		return nil, err
	}
	return value, nil
}

func validateObjectUID(value *unstructured.Unstructured, identity Identity) error {
	if value == nil {
		return errors.New("Kubernetes object is missing")
	}
	if string(value.GetUID()) == identity.UID {
		return nil
	}
	return &IdentityChangedError{
		ExpectedUID: identity.UID,
		ActualUID:   string(value.GetUID()),
		Namespace:   identity.Namespace,
		Name:        identity.Name,
	}
}

type Detail struct {
	Identity        Identity
	ResourceVersion string
	YAML            []byte
	Labels          map[string]string
	Annotations     map[string]string
	Summary         []SummaryField
	Containers      []ContainerDetail
	Owners          []OwnerReference
	// PodLabelSelector is the canonical, restrictive Kubernetes selector
	// carried by supported built-in Pod controllers and Services. An empty
	// value is deliberately unusable as a drill-down: the Kubernetes API
	// interprets an empty labelSelector query as matching every object.
	PodLabelSelector string
	// object is the same fresh, UID-validated value used to build the detail.
	// It stays package-private so optional enrichers can calculate from the
	// authoritative read without performing a second GET or exposing raw
	// Secret data through the response contract.
	object *unstructured.Unstructured
}

// OwnerReference is the bounded, display-safe owner projection carried with
// an authoritative object detail. Parent navigation uses it to choose a
// target resource; child discovery and relationship scans are intentionally
// outside this contract.
type OwnerReference struct {
	Group      string
	Version    string
	Kind       string
	Name       string
	UID        string
	Controller bool
}

type SummaryField struct {
	Section               string
	ID                    string
	Label                 string
	Value                 string
	Timestamp             time.Time
	TimestampPresentation SummaryTimestampPresentation
}

type SummaryTimestampPresentation int

const (
	SummaryTimestampElapsedSince SummaryTimestampPresentation = iota + 1
	SummaryTimestampOccurredAt
)

func (r *Reader) Detail(ctx context.Context, identity Identity, includeYAML, includeSummary bool) (Detail, error) {
	value, err := r.Get(ctx, identity)
	if err != nil {
		return Detail{}, err
	}
	return detailFromObject(value, identity, includeYAML, includeSummary)
}

func detailFromObject(
	value *unstructured.Unstructured,
	identity Identity,
	includeYAML, includeSummary bool,
) (Detail, error) {
	if err := validateObjectUID(value, identity); err != nil {
		return Detail{}, err
	}
	detail := Detail{
		Identity:         identity,
		ResourceVersion:  value.GetResourceVersion(),
		Labels:           cloneStrings(value.GetLabels()),
		Annotations:      cloneStrings(value.GetAnnotations()),
		PodLabelSelector: canonicalPodLabelSelector(value.Object, identity),
		object:           value,
	}
	if includeYAML {
		// YAML is a display/editing projection. Keep the authoritative object
		// untouched because summaries, metrics, and mutation checks still need
		// the server-managed metadata. The edit path likewise compares against a
		// fresh object and deliberately excludes managedFields from its patch.
		display := value.DeepCopy()
		unstructured.RemoveNestedField(display.Object, "metadata", "managedFields")
		jsonBytes, err := display.MarshalJSON()
		if err != nil {
			return Detail{}, fmt.Errorf("marshal Kubernetes object: %w", err)
		}
		detail.YAML, err = yaml.JSONToYAML(jsonBytes)
		if err != nil {
			return Detail{}, fmt.Errorf("format Kubernetes YAML: %w", err)
		}
	}
	if includeSummary {
		detail.Summary = summarizeForIdentity(value, identity)
		detail.Owners = ownerReferences(value)
		if identity.Group == "" && identity.Version == "v1" && identity.Resource == "pods" {
			detail.Containers = podContainerDetails(value)
		}
	}
	return detail, nil
}

func ownerReferences(value *unstructured.Unstructured) []OwnerReference {
	if value == nil {
		return nil
	}
	owners := value.GetOwnerReferences()
	if len(owners) > maximumSummaryOwners {
		owners = owners[:maximumSummaryOwners]
	}
	result := make([]OwnerReference, 0, len(owners))
	for _, owner := range owners {
		if owner.Name == "" || owner.UID == "" || owner.Kind == "" || owner.APIVersion == "" {
			continue
		}
		groupVersion, err := schema.ParseGroupVersion(owner.APIVersion)
		if err != nil || groupVersion.Version == "" {
			continue
		}
		result = append(result, OwnerReference{
			Group: groupVersion.Group, Version: groupVersion.Version,
			Kind: owner.Kind, Name: owner.Name, UID: string(owner.UID),
			Controller: owner.Controller != nil && *owner.Controller,
		})
	}
	return result
}

// canonicalPodLabelSelector converts the authoritative built-in object's Pod
// selector with Kubernetes' own validation and serialization rules. Missing,
// malformed, and match-everything selectors are all omitted: returning an
// empty selector to a Pod LIST/WATCH would otherwise broaden the drill-down to
// every Pod in its namespace scope.
func canonicalPodLabelSelector(object map[string]any, identity Identity) string {
	var (
		selector labels.Selector
		err      error
	)
	switch identity.GVR() {
	case schema.GroupVersionResource{Version: "v1", Resource: "services"},
		schema.GroupVersionResource{Version: "v1", Resource: "replicationcontrollers"}:
		values, found, nestedErr := unstructured.NestedStringMap(object, "spec", "selector")
		if nestedErr != nil || !found || len(values) == 0 {
			return ""
		}
		selector, err = labels.ValidatedSelectorFromSet(labels.Set(values))
	case schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "deployments"},
		schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "statefulsets"},
		schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "daemonsets"},
		schema.GroupVersionResource{Group: "apps", Version: "v1", Resource: "replicasets"},
		schema.GroupVersionResource{Group: "batch", Version: "v1", Resource: "jobs"}:
		raw, found, nestedErr := unstructured.NestedMap(object, "spec", "selector")
		if nestedErr != nil || !found || len(raw) == 0 {
			return ""
		}
		var value metav1.LabelSelector
		if err = k8sruntime.DefaultUnstructuredConverter.FromUnstructured(raw, &value); err == nil {
			selector, err = metav1.LabelSelectorAsSelector(&value)
		}
	default:
		return ""
	}
	if err != nil || selector == nil || selector.Empty() {
		return ""
	}
	return selector.String()
}

type DataKind uint8

const (
	DataText DataKind = iota + 1
	DataBinary
)

type DataEntry struct {
	Key         string
	Kind        DataKind
	Value       []byte
	ContentHash [sha256.Size]byte
}

type Data struct {
	Identity        Identity
	ResourceVersion string
	Secret          bool
	Entries         []DataEntry
}

// GetData returns raw decoded bytes. Secret values are never converted to
// display strings here and this type intentionally has no String method.
func (r *Reader) GetData(ctx context.Context, identity Identity) (Data, error) {
	value, err := r.Get(ctx, identity)
	if err != nil {
		return Data{}, err
	}
	result := Data{Identity: identity, ResourceVersion: value.GetResourceVersion()}
	switch {
	case identity.Group == "" && identity.Version == "v1" && identity.Resource == "configmaps":
		entries, err := configMapEntries(value.Object)
		if err != nil {
			return Data{}, err
		}
		result.Entries = entries
	case identity.Group == "" && identity.Version == "v1" && identity.Resource == "secrets":
		entries, err := secretEntries(value.Object)
		if err != nil {
			return Data{}, err
		}
		result.Secret = true
		result.Entries = entries
	default:
		return Data{}, ErrUnsupportedDataObject
	}
	return result, nil
}

func configMapEntries(value map[string]any) ([]DataEntry, error) {
	entries := make(map[string]DataEntry)
	if text, found, err := unstructured.NestedStringMap(value, "data"); err != nil {
		return nil, fmt.Errorf("read ConfigMap data: %w", err)
	} else if found {
		for key, item := range text {
			bytes := []byte(item)
			entries[key] = newDataEntry(key, DataText, bytes)
		}
	}
	if binary, found, err := unstructured.NestedStringMap(value, "binaryData"); err != nil {
		return nil, fmt.Errorf("read ConfigMap binaryData: %w", err)
	} else if found {
		for key, encoded := range binary {
			if _, duplicate := entries[key]; duplicate {
				return nil, fmt.Errorf("ConfigMap key %q occurs in both data and binaryData", key)
			}
			bytes, err := decodeKubernetesBase64(encoded)
			if err != nil {
				return nil, fmt.Errorf("decode ConfigMap binaryData key %q: %w", key, err)
			}
			entries[key] = newDataEntry(key, DataBinary, bytes)
		}
	}
	return sortedDataEntries(entries), nil
}

func secretEntries(value map[string]any) ([]DataEntry, error) {
	encoded, found, err := unstructured.NestedStringMap(value, "data")
	if err != nil {
		return nil, fmt.Errorf("read Secret data: %w", err)
	}
	if !found {
		return nil, nil
	}
	entries := make(map[string]DataEntry, len(encoded))
	for key, item := range encoded {
		bytes, err := decodeKubernetesBase64(item)
		if err != nil {
			return nil, fmt.Errorf("decode Secret data key %q: %w", key, err)
		}
		kind := DataBinary
		if isSafeUTF8(bytes) {
			kind = DataText
		}
		entries[key] = newDataEntry(key, kind, bytes)
	}
	return sortedDataEntries(entries), nil
}

func decodeKubernetesBase64(value string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err == nil {
		return decoded, nil
	}
	// Kubernetes JSON normally uses padded standard base64. Accept raw standard
	// encoding as a defensive compatibility measure, never URL encoding.
	return base64.RawStdEncoding.DecodeString(value)
}

func newDataEntry(key string, kind DataKind, value []byte) DataEntry {
	copy := slices.Clone(value)
	return DataEntry{Key: key, Kind: kind, Value: copy, ContentHash: sha256.Sum256(copy)}
}

func sortedDataEntries(entries map[string]DataEntry) []DataEntry {
	result := make([]DataEntry, 0, len(entries))
	for _, entry := range entries {
		result = append(result, entry)
	}
	slices.SortFunc(result, func(a, b DataEntry) int { return strings.Compare(a.Key, b.Key) })
	return result
}

func isSafeUTF8(value []byte) bool {
	return strings.ToValidUTF8(string(value), "\x00") == string(value) && !strings.ContainsRune(string(value), '\x00')
}

func summarize(value *unstructured.Unstructured) []SummaryField {
	return summarizeWithKind(value, value.GetKind())
}

// summarizeForIdentity keeps resource-specific projections tied to the
// authoritative detail identity. An API server (or a fake client) may omit or
// vary TypeMeta on an otherwise complete object, while a core/v1 nodes GVR is
// sufficient to select the Node projection.
func summarizeForIdentity(value *unstructured.Unstructured, identity Identity) []SummaryField {
	kind := value.GetKind()
	if identity.Group == "" && identity.Version == "v1" && identity.Resource == "nodes" {
		kind = "Node"
	}
	return summarizeWithKind(value, kind)
}

func summarizeWithKind(value *unstructured.Unstructured, kind string) []SummaryField {
	fields := []SummaryField{
		{Section: "identity", ID: "kind", Label: "Kind", Value: boundedSummaryText(kind)},
		{Section: "identity", ID: "namespace", Label: "Namespace", Value: boundedSummaryText(valueOrDash(value.GetNamespace()))},
		{Section: "identity", ID: "name", Label: "Name", Value: boundedSummaryText(value.GetName())},
		{Section: "identity", ID: "uid", Label: "UID", Value: boundedSummaryText(string(value.GetUID()))},
		{Section: "identity", ID: "resourceVersion", Label: "Resource Version", Value: boundedSummaryText(value.GetResourceVersion())},
	}
	if created := value.GetCreationTimestamp(); !created.IsZero() {
		fields = append(fields, SummaryField{
			Section: "identity", ID: "created", Label: "Created", Value: created.Time.Format("2006-01-02 15:04:05Z07:00"),
		})
	}
	if generation := value.GetGeneration(); generation > 0 {
		fields = append(fields, SummaryField{
			Section: "identity", ID: "generation", Label: "Generation", Value: fmt.Sprint(generation),
		})
	}
	if deleted := value.GetDeletionTimestamp(); deleted != nil && !deleted.IsZero() {
		fields = append(fields, SummaryField{
			Section: "identity", ID: "deleting", Label: "Deleting Since",
			Value: deleted.Time.Format("2006-01-02 15:04:05Z07:00"),
		})
	}

	// Secret payloads can occur under data, stringData, or provider-specific
	// status fields. Keep their summary strictly metadata-only; decoded values
	// remain exclusive to the explicitly revealed Data surface.
	if kind != "Secret" {
		fields = append(fields, genericStatusSummary(value.Object)...)
		fields = append(fields, conditionSummary(value.Object)...)
	}
	fields = append(fields, ownerReferenceSummary(value)...)

	switch kind {
	case "Pod":
		fields = append(fields, podRestartSummary(value.Object)...)
		fields = append(fields, podOverviewSummary(value.Object)...)
		fields = append(fields, podContainerSummary(value.Object)...)
	case "Node":
		fields = append(fields, nodeSummary(value)...)
	case "Service":
		fields = append(fields, serviceOverviewSummary(value.Object)...)
		fields = append(fields, servicePortSummary(value.Object)...)
	case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job":
		fields = append(fields, workloadSelectorSummary(value.Object)...)
	case "ReplicationController":
		fields = append(fields, flatSelectorSummary(value.Object, "spec", "selector")...)
	case "Secret":
		if secretType, found, _ := unstructured.NestedString(value.Object, "type"); found && secretType != "" {
			fields = append(fields, SummaryField{
				Section: "secret", ID: "type", Label: "Type", Value: secretType,
			})
		}
	}
	// Apply one final bound to every presentation string, including fields
	// produced by resource-specific helpers. This keeps future helpers from
	// accidentally turning untrusted API values into an unbounded UI response.
	for index := range fields {
		fields[index].Label = boundedSummaryLabel(fields[index].Label)
		fields[index].Value = boundedSummaryText(fields[index].Value)
	}
	return fields
}

const (
	maximumSummaryContainers    = 64
	maximumSummaryPorts         = 128
	maximumSummaryConditions    = 64
	maximumSummaryOwners        = 64
	maximumSummarySelectors     = 64
	maximumSummaryAddresses     = 64
	maximumSummaryNodeTaints    = 64
	maximumSummaryNodeCIDRs     = 64
	maximumSummaryNodeResources = 64
	maximumSummaryNodeRoles     = 64
	maximumSummaryNameBytes     = 253
	maximumSummaryPortNameBytes = 63
	// A qualified Kubernetes label key can contain a 253-byte DNS prefix,
	// one slash, and a 63-byte name. Preserve it exactly so selector summaries
	// remain safe machine-readable drill-down inputs as well as presentation.
	maximumSummaryLabelBytes = 320
	maximumSummaryValueBytes = 512
)

func genericStatusSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 8)
	if phase, found, _ := unstructured.NestedString(object, "status", "phase"); found && phase != "" {
		result = append(result, SummaryField{
			Section: "status", ID: "phase", Label: "Status", Value: boundedSummaryText(phase),
		})
	}
	integerFields := []struct {
		path    []string
		id      string
		label   string
		section string
	}{
		{path: []string{"status", "observedGeneration"}, id: "observedGeneration", label: "Observed Generation", section: "status"},
		{path: []string{"spec", "replicas"}, id: "desiredReplicas", label: "Desired Replicas", section: "replicas"},
		{path: []string{"status", "replicas"}, id: "replicas", label: "Current Replicas", section: "replicas"},
		{path: []string{"status", "readyReplicas"}, id: "readyReplicas", label: "Ready Replicas", section: "replicas"},
		{path: []string{"status", "availableReplicas"}, id: "availableReplicas", label: "Available Replicas", section: "replicas"},
		{path: []string{"status", "updatedReplicas"}, id: "updatedReplicas", label: "Updated Replicas", section: "replicas"},
		{path: []string{"status", "unavailableReplicas"}, id: "unavailableReplicas", label: "Unavailable Replicas", section: "replicas"},
	}
	for _, field := range integerFields {
		if number, found, _ := unstructured.NestedInt64(object, field.path...); found {
			result = append(result, SummaryField{
				Section: field.section, ID: field.id, Label: field.label, Value: fmt.Sprint(number),
			})
		}
	}
	return result
}

func conditionSummary(object map[string]any) []SummaryField {
	conditions, found, err := unstructured.NestedSlice(object, "status", "conditions")
	if err != nil || !found {
		return nil
	}
	originalCount := len(conditions)
	if len(conditions) > maximumSummaryConditions {
		conditions = conditions[:maximumSummaryConditions]
	}
	result := make([]SummaryField, 0, len(conditions)+1)
	for index, raw := range conditions {
		condition, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		typeName, _, _ := unstructured.NestedString(condition, "type")
		status, _, _ := unstructured.NestedString(condition, "status")
		reason, _, _ := unstructured.NestedString(condition, "reason")
		message, _, _ := unstructured.NestedString(condition, "message")
		transitioned, _, _ := unstructured.NestedString(condition, "lastTransitionTime")
		transitionTime, _ := time.Parse(time.RFC3339, transitioned)
		if typeName == "" && status == "" && reason == "" && message == "" {
			continue
		}
		label := boundedSummaryLabel(typeName)
		if label == "" {
			label = fmt.Sprintf("Condition %d", index+1)
		}
		parts := make([]string, 0, 4)
		if status != "" {
			parts = append(parts, status)
		}
		if reason != "" {
			parts = append(parts, reason)
		}
		if message != "" {
			parts = append(parts, message)
		}
		result = append(result, SummaryField{
			Section: "conditions", ID: fmt.Sprintf("condition:%d", index), Label: label,
			Value: boundedSummaryText(strings.Join(parts, " · ")), Timestamp: transitionTime,
			TimestampPresentation: SummaryTimestampElapsedSince,
		})
	}
	if omitted := originalCount - len(conditions); omitted > 0 {
		result = append(result, omittedSummaryField("conditions", "conditionsOmitted", "Conditions", omitted))
	}
	return result
}

func ownerReferenceSummary(value *unstructured.Unstructured) []SummaryField {
	owners := value.GetOwnerReferences()
	originalCount := len(owners)
	if len(owners) > maximumSummaryOwners {
		owners = owners[:maximumSummaryOwners]
	}
	result := make([]SummaryField, 0, len(owners)+1)
	for index, owner := range owners {
		name := boundedSummaryText(owner.Name)
		if name == "" {
			continue
		}
		kind := boundedSummaryLabel(owner.Kind)
		if kind == "" {
			kind = "Object"
		}
		parts := []string{kind + "/" + name}
		if owner.Controller != nil && *owner.Controller {
			parts = append(parts, "controller")
		}
		if uid := boundedSummaryText(string(owner.UID)); uid != "" {
			parts = append(parts, "UID "+uid)
		}
		result = append(result, SummaryField{
			Section: "owners", ID: fmt.Sprintf("owner:%d", index), Label: "Owner",
			Value: boundedSummaryText(strings.Join(parts, " · ")),
		})
	}
	if omitted := originalCount - len(owners); omitted > 0 {
		result = append(result, omittedSummaryField("owners", "ownersOmitted", "Owner References", omitted))
	}
	return result
}

func podOverviewSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0, 3)
	for _, field := range []struct {
		path  []string
		id    string
		label string
	}{
		{path: []string{"spec", "nodeName"}, id: "node", label: "Node"},
		{path: []string{"status", "podIP"}, id: "podIP", label: "Pod IP"},
		{path: []string{"status", "hostIP"}, id: "hostIP", label: "Host IP"},
	} {
		if value, found, _ := unstructured.NestedString(object, field.path...); found && value != "" {
			result = append(result, SummaryField{
				Section: "network", ID: field.id, Label: field.label, Value: boundedSummaryText(value),
			})
		}
	}
	return result
}

// nodeSummary projects the parts of a core/v1 Node that are useful while
// inspecting one selected object. The list view already exposes a compact
// subset of these values; Details can afford to show the individual entries
// without fetching any additional resources. Every collection is bounded so
// an unusually large or malformed Node cannot create an unbounded IPC/UI
// response.
func nodeSummary(value *unstructured.Unstructured) []SummaryField {
	if value == nil {
		return nil
	}
	result := make([]SummaryField, 0, 24)
	result = append(result, nodeSchedulingSummary(value)...)
	result = append(result, nodeNetworkSummary(value)...)
	result = append(result, nodeResourceSummary(value)...)
	result = append(result, nodeSystemSummary(value)...)
	return result
}

func nodeSchedulingSummary(value *unstructured.Unstructured) []SummaryField {
	result := make([]SummaryField, 0, 4)

	roles := nodeSummaryRoles(value.GetLabels())
	omittedRoles := 0
	if len(roles) > maximumSummaryNodeRoles {
		omittedRoles = len(roles) - maximumSummaryNodeRoles
		roles = roles[:maximumSummaryNodeRoles]
	}
	roleValue := "None"
	if len(roles) > 0 {
		roleValue = strings.Join(roles, ", ")
	}
	result = append(result, SummaryField{
		Section: "scheduling", ID: "roles", Label: "Roles", Value: roleValue,
	})
	if omittedRoles > 0 {
		result = append(result, omittedSummaryField(
			"scheduling", "rolesOmitted", "Roles", omittedRoles,
		))
	}

	unschedulable := false
	if reported, found, err := unstructured.NestedBool(value.Object, "spec", "unschedulable"); err == nil {
		unschedulable = found && reported
		result = append(result, SummaryField{
			Section: "scheduling", ID: "unschedulable", Label: "Unschedulable",
			Value: strconv.FormatBool(unschedulable),
		})
	}

	taints, found, err := unstructured.NestedSlice(value.Object, "spec", "taints")
	if err != nil || !found || len(taints) == 0 {
		result = append(result, SummaryField{
			Section: "scheduling", ID: "taints", Label: "Taints", Value: "None",
		})
		return result
	}

	omitted := 0
	displayedTaint := false
	for index, raw := range taints {
		if index >= maximumSummaryNodeTaints {
			omitted++
			continue
		}
		taint, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		key := summaryMapString(taint, "key")
		valueText := summaryMapString(taint, "value")
		effect := summaryMapString(taint, "effect")
		text := formatNodeTaint(key, valueText, effect)
		if text == "" {
			omitted++
			continue
		}
		result = append(result, SummaryField{
			Section: "scheduling", ID: fmt.Sprintf("taint:%d", index),
			Label: "Taint", Value: text,
		})
		displayedTaint = true
	}
	if omitted > 0 {
		result = append(result, omittedSummaryField(
			"scheduling", "taintsOmitted", "Taints", omitted,
		))
	}
	// A malformed list can contain no displayable entries. Keep the section
	// explicit in that case so Details does not imply that taints were absent.
	if !displayedTaint {
		result = append(result, SummaryField{
			Section: "scheduling", ID: "taints", Label: "Taints", Value: "None",
		})
	}
	return result
}

func nodeSummaryRoles(labels map[string]string) []string {
	const prefix = "node-role.kubernetes.io/"
	roles := make([]string, 0)
	seen := make(map[string]struct{})
	for key := range labels {
		role, found := strings.CutPrefix(key, prefix)
		if !found || role == "" || !validSummaryToken(role, maximumSummaryNameBytes) {
			continue
		}
		if _, duplicate := seen[role]; duplicate {
			continue
		}
		seen[role] = struct{}{}
		roles = append(roles, role)
	}
	if role := labels["kubernetes.io/role"]; validSummaryToken(role, maximumSummaryNameBytes) {
		if _, duplicate := seen[role]; !duplicate {
			roles = append(roles, role)
		}
	}
	slices.Sort(roles)
	return roles
}

func formatNodeTaint(key, value, effect string) string {
	key = boundedSummaryText(key)
	value = boundedSummaryText(value)
	effect = boundedSummaryText(effect)
	if key == "" && value == "" && effect == "" {
		return ""
	}
	text := key
	if text == "" {
		text = "<unnamed>"
	}
	if value != "" {
		text += "=" + value
	}
	if effect != "" {
		text += ":" + effect
	}
	return boundedSummaryText(text)
}

func nodeNetworkSummary(value *unstructured.Unstructured) []SummaryField {
	result := make([]SummaryField, 0, 8)
	addresses, found, err := unstructured.NestedSlice(value.Object, "status", "addresses")
	if err != nil || !found || len(addresses) == 0 {
		result = append(result, SummaryField{
			Section: "network", ID: "addresses", Label: "Addresses", Value: "None",
		})
	} else {
		result = append(result, nodeAddressFields(addresses)...)
	}

	cidrs, omittedCIDRs := nodePodCIDRs(value.Object)
	for index, cidr := range cidrs {
		result = append(result, SummaryField{
			Section: "network", ID: fmt.Sprintf("podCIDR:%d", index),
			Label: "Pod CIDR", Value: cidr,
		})
	}
	if omittedCIDRs > 0 {
		result = append(result, omittedSummaryField(
			"network", "podCIDRsOmitted", "Pod CIDRs", omittedCIDRs,
		))
	}
	return result
}

type nodeSummaryAddress struct {
	typeName string
	address  string
}

func nodeAddressFields(rawAddresses []any) []SummaryField {
	addresses := make([]nodeSummaryAddress, 0, min(len(rawAddresses), maximumSummaryAddresses))
	seen := make(map[string]struct{})
	omitted := 0
	for _, raw := range rawAddresses {
		entry, ok := raw.(map[string]any)
		if !ok {
			omitted++
			continue
		}
		typeName := summaryMapString(entry, "type")
		address := summaryMapString(entry, "address")
		if typeName == "" || address == "" {
			omitted++
			continue
		}
		typeName = boundedSummaryText(typeName)
		address = boundedSummaryText(address)
		key := typeName + "\x00" + address
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		if len(addresses) >= maximumSummaryAddresses {
			omitted++
			continue
		}
		addresses = append(addresses, nodeSummaryAddress{typeName: typeName, address: address})
	}
	slices.SortFunc(addresses, func(left, right nodeSummaryAddress) int {
		leftPriority := nodeAddressTypePriority(left.typeName)
		rightPriority := nodeAddressTypePriority(right.typeName)
		if leftPriority != rightPriority {
			if leftPriority < rightPriority {
				return -1
			}
			return 1
		}
		if left.typeName != right.typeName {
			return strings.Compare(left.typeName, right.typeName)
		}
		return strings.Compare(left.address, right.address)
	})

	result := make([]SummaryField, 0, len(addresses)+1)
	for index, address := range addresses {
		result = append(result, SummaryField{
			Section: "network", ID: fmt.Sprintf("address:%d", index),
			Label: nodeAddressLabel(address.typeName), Value: address.address,
		})
	}
	if omitted > 0 {
		result = append(result, omittedSummaryField(
			"network", "addressesOmitted", "Addresses", omitted,
		))
	}
	if len(result) == 0 {
		result = append(result, SummaryField{
			Section: "network", ID: "addresses", Label: "Addresses", Value: "None",
		})
	}
	return result
}

func nodeAddressTypePriority(typeName string) int {
	switch typeName {
	case "Hostname":
		return 0
	case "InternalIP":
		return 1
	case "ExternalIP":
		return 2
	case "InternalDNS":
		return 3
	case "ExternalDNS":
		return 4
	default:
		return 100
	}
}

func nodeAddressLabel(typeName string) string {
	switch typeName {
	case "InternalIP":
		return "Internal IP"
	case "ExternalIP":
		return "External IP"
	case "InternalDNS":
		return "Internal DNS"
	case "ExternalDNS":
		return "External DNS"
	default:
		return typeName
	}
}

func nodePodCIDRs(object map[string]any) ([]string, int) {
	values := make([]string, 0)
	seen := make(map[string]struct{})
	omitted := 0
	appendValue := func(value string) {
		value = boundedSummaryText(value)
		if value == "" {
			omitted++
			return
		}
		if _, duplicate := seen[value]; duplicate {
			return
		}
		if len(values) >= maximumSummaryNodeCIDRs {
			omitted++
			return
		}
		seen[value] = struct{}{}
		values = append(values, value)
	}
	if raw, found, err := unstructured.NestedFieldNoCopy(object, "spec", "podCIDRs"); err == nil && found {
		switch cidrs := raw.(type) {
		case []any:
			for _, rawCIDR := range cidrs {
				cidr, _ := rawCIDR.(string)
				appendValue(cidr)
			}
		case []string:
			for _, cidr := range cidrs {
				appendValue(cidr)
			}
		}
	}
	if cidr, found, err := unstructured.NestedString(object, "spec", "podCIDR"); err == nil && found {
		appendValue(cidr)
	}
	return values, omitted
}

func nodeResourceSummary(value *unstructured.Unstructured) []SummaryField {
	capacity := nodeResourceValues(value.Object, "status", "capacity")
	allocatable := nodeResourceValues(value.Object, "status", "allocatable")
	if len(capacity) == 0 && len(allocatable) == 0 {
		return nil
	}

	namesByResource := make(map[string]struct{}, len(capacity)+len(allocatable))
	for name := range capacity {
		namesByResource[name] = struct{}{}
	}
	for name := range allocatable {
		namesByResource[name] = struct{}{}
	}
	names := make([]string, 0, len(namesByResource))
	for name := range namesByResource {
		names = append(names, name)
	}
	slices.Sort(names)
	omitted := 0
	if len(names) > maximumSummaryNodeResources {
		omitted = len(names) - maximumSummaryNodeResources
		names = names[:maximumSummaryNodeResources]
	}

	result := make([]SummaryField, 0, len(names)*2+1)
	for _, name := range names {
		friendlyName := nodeResourceLabel(name)
		if quantity, found := allocatable[name]; found {
			result = append(result, SummaryField{
				Section: "resources", ID: "allocatable:" + name,
				Label: "Allocatable " + friendlyName, Value: quantity,
			})
		}
		if quantity, found := capacity[name]; found {
			result = append(result, SummaryField{
				Section: "resources", ID: "capacity:" + name,
				Label: "Capacity " + friendlyName, Value: quantity,
			})
		}
	}
	if omitted > 0 {
		result = append(result, omittedSummaryField(
			"resources", "resourcesOmitted", "Resources", omitted,
		))
	}
	return result
}

func nodeResourceValues(object map[string]any, path ...string) map[string]string {
	raw, found, err := unstructured.NestedFieldNoCopy(object, path...)
	if err != nil || !found {
		return nil
	}
	result := make(map[string]string)
	switch values := raw.(type) {
	case map[string]any:
		for name, value := range values {
			if !validSummaryToken(name, maximumSummaryLabelBytes) {
				continue
			}
			if quantity, ok := summaryQuantityText(value); ok {
				result[name] = quantity
			}
		}
	case map[string]string:
		for name, value := range values {
			if !validSummaryToken(name, maximumSummaryLabelBytes) {
				continue
			}
			if quantity, ok := summaryQuantityText(value); ok {
				result[name] = quantity
			}
		}
	}
	return result
}

func summaryQuantityText(value any) (string, bool) {
	var text string
	switch typed := value.(type) {
	case string:
		text = typed
	case json.Number:
		text = typed.String()
	case int:
		text = strconv.Itoa(typed)
	case int32:
		text = strconv.FormatInt(int64(typed), 10)
	case int64:
		text = strconv.FormatInt(typed, 10)
	case uint:
		text = strconv.FormatUint(uint64(typed), 10)
	case uint32:
		text = strconv.FormatUint(uint64(typed), 10)
	case uint64:
		text = strconv.FormatUint(typed, 10)
	case float32:
		text = strconv.FormatFloat(float64(typed), 'g', -1, 32)
	case float64:
		text = strconv.FormatFloat(typed, 'g', -1, 64)
	case resource.Quantity:
		text = typed.String()
	case *resource.Quantity:
		if typed == nil {
			return "", false
		}
		text = typed.String()
	default:
		return "", false
	}
	text = strings.TrimSpace(text)
	if text == "" || len(text) > maximumSummaryValueBytes {
		return "", false
	}
	if _, err := resource.ParseQuantity(text); err != nil {
		return "", false
	}
	return boundedSummaryText(text), true
}

func nodeResourceLabel(name string) string {
	switch name {
	case "cpu":
		return "CPU"
	case "memory":
		return "Memory"
	case "ephemeral-storage":
		return "Ephemeral Storage"
	case "pods":
		return "Pods"
	default:
		return name
	}
}

func nodeSystemSummary(value *unstructured.Unstructured) []SummaryField {
	result := make([]SummaryField, 0, 12)
	for _, field := range []struct {
		path  []string
		id    string
		label string
	}{
		{path: []string{"spec", "providerID"}, id: "providerID", label: "Provider ID"},
		{path: []string{"spec", "externalID"}, id: "externalID", label: "External ID"},
		{path: []string{"status", "nodeInfo", "machineID"}, id: "machineID", label: "Machine ID"},
		{path: []string{"status", "nodeInfo", "systemUUID"}, id: "systemUUID", label: "System UUID"},
		{path: []string{"status", "nodeInfo", "bootID"}, id: "bootID", label: "Boot ID"},
		{path: []string{"status", "nodeInfo", "kernelVersion"}, id: "kernelVersion", label: "Kernel Version"},
		{path: []string{"status", "nodeInfo", "osImage"}, id: "osImage", label: "OS Image"},
		{path: []string{"status", "nodeInfo", "containerRuntimeVersion"}, id: "containerRuntimeVersion", label: "Container Runtime Version"},
		{path: []string{"status", "nodeInfo", "kubeletVersion"}, id: "kubeletVersion", label: "Kubelet Version"},
		{path: []string{"status", "nodeInfo", "kubeProxyVersion"}, id: "kubeProxyVersion", label: "Kube-Proxy Version"},
		{path: []string{"status", "nodeInfo", "operatingSystem"}, id: "operatingSystem", label: "Operating System"},
		{path: []string{"status", "nodeInfo", "architecture"}, id: "architecture", label: "Architecture"},
	} {
		text, found, err := unstructured.NestedString(value.Object, field.path...)
		if err != nil || !found || text == "" {
			continue
		}
		result = append(result, SummaryField{
			Section: "system", ID: field.id, Label: field.label,
			Value: boundedSummaryText(text),
		})
	}
	return result
}

func summaryMapString(value map[string]any, key string) string {
	text, _ := value[key].(string)
	return text
}

func podRestartSummary(object map[string]any) []SummaryField {
	status, _ := object["status"].(map[string]any)
	type termination struct {
		reason      string
		exitCode    int64
		hasExitCode bool
		finished    time.Time
	}
	var fallback, latest termination
	hasFallback := false
	for _, field := range []string{
		"containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses",
	} {
		statuses, _ := status[field].([]any)
		for _, raw := range statuses {
			containerStatus, _ := raw.(map[string]any)
			lastState, _ := containerStatus["lastState"].(map[string]any)
			terminated, _ := lastState["terminated"].(map[string]any)
			reason, _ := terminated["reason"].(string)
			reason = boundedSummaryText(reason)
			if reason == "" {
				continue
			}
			finishedAt, _ := terminated["finishedAt"].(string)
			finished, err := time.Parse(time.RFC3339Nano, finishedAt)
			if err != nil {
				finished = time.Time{}
			}
			exitCode, hasExitCode, _ := unstructured.NestedInt64(terminated, "exitCode")
			candidate := termination{
				reason: reason, exitCode: exitCode, hasExitCode: hasExitCode,
				finished: finished,
			}
			if !hasFallback {
				fallback = candidate
				hasFallback = true
			}
			if !finished.IsZero() && (latest.finished.IsZero() || finished.After(latest.finished)) {
				latest = candidate
			}
		}
	}
	selected := latest
	if selected.reason == "" {
		selected = fallback
	}
	if selected.reason == "" {
		return nil
	}
	parts := []string{selected.reason}
	if selected.hasExitCode {
		parts = append(parts, fmt.Sprintf("Exit code %d", selected.exitCode))
	}
	return []SummaryField{{
		Section: "status", ID: "lastRestartReason", Label: "Last Restart Reason",
		Value:     boundedSummaryText(strings.Join(parts, " · ")),
		Timestamp: selected.finished, TimestampPresentation: SummaryTimestampOccurredAt,
	}}
}

func serviceOverviewSummary(object map[string]any) []SummaryField {
	result := make([]SummaryField, 0)
	for _, field := range []struct {
		path  []string
		id    string
		label string
	}{
		{path: []string{"spec", "type"}, id: "type", label: "Type"},
		{path: []string{"spec", "clusterIP"}, id: "clusterIP", label: "Cluster IP"},
		{path: []string{"spec", "externalName"}, id: "externalName", label: "External Name"},
	} {
		if value, found, _ := unstructured.NestedString(object, field.path...); found && value != "" {
			result = append(result, SummaryField{
				Section: "service", ID: field.id, Label: field.label, Value: boundedSummaryText(value),
			})
		}
	}

	result = append(result, flatSelectorSummary(object, "spec", "selector")...)

	result = append(result, serviceAddressSummary(object)...)
	return result
}

func flatSelectorSummary(object map[string]any, path ...string) []SummaryField {
	result := make([]SummaryField, 0)
	selectors, found, err := unstructured.NestedStringMap(object, path...)
	if err == nil && found {
		keys := make([]string, 0, len(selectors))
		for key := range selectors {
			keys = append(keys, key)
		}
		slices.Sort(keys)
		originalCount := len(keys)
		if len(keys) > maximumSummarySelectors {
			keys = keys[:maximumSummarySelectors]
		}
		for index, key := range keys {
			result = append(result, SummaryField{
				Section: "selectors", ID: fmt.Sprintf("selector:%d", index),
				Label: boundedSummaryLabel(key), Value: boundedSummaryText(selectors[key]),
			})
		}
		if omitted := originalCount - len(keys); omitted > 0 {
			result = append(result, omittedSummaryField("selectors", "selectorsOmitted", "Selectors", omitted))
		}
	}
	return result
}

func workloadSelectorSummary(object map[string]any) []SummaryField {
	result := flatSelectorSummary(object, "spec", "selector", "matchLabels")
	expressions, found, err := unstructured.NestedSlice(
		object, "spec", "selector", "matchExpressions",
	)
	if err == nil && found && len(expressions) > 0 {
		result = append(result, SummaryField{
			Section: "selectors", ID: "selectorExpressions", Label: "Match Expressions",
			Value: fmt.Sprintf("%d cannot be represented by the resource filter", len(expressions)),
		})
	}
	return result
}

func serviceAddressSummary(object map[string]any) []SummaryField {
	addresses := make([]SummaryField, 0)
	omitted := 0
	appendAddress := func(id, label, value string) {
		value = boundedSummaryText(value)
		if value == "" {
			return
		}
		if len(addresses) >= maximumSummaryAddresses {
			omitted++
			return
		}
		addresses = append(addresses, SummaryField{
			Section: "endpoints", ID: fmt.Sprintf("%s:%d", id, len(addresses)),
			Label: label, Value: value,
		})
	}
	if externalIPs, found, _ := unstructured.NestedStringSlice(object, "spec", "externalIPs"); found {
		for _, address := range externalIPs {
			appendAddress("externalIP", "External IP", address)
		}
	}
	ingress, found, err := unstructured.NestedSlice(object, "status", "loadBalancer", "ingress")
	if err == nil && found {
		for _, raw := range ingress {
			entry, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if ip, _, _ := unstructured.NestedString(entry, "ip"); ip != "" {
				appendAddress("loadBalancer", "Load Balancer", ip)
			} else if hostname, _, _ := unstructured.NestedString(entry, "hostname"); hostname != "" {
				appendAddress("loadBalancer", "Load Balancer", hostname)
			}
		}
	}
	if omitted > 0 {
		addresses = append(addresses, omittedSummaryField(
			"endpoints", "endpointsOmitted", "Endpoint Addresses", omitted,
		))
	}
	return addresses
}

func podContainerSummary(object map[string]any) []SummaryField {
	type containerGroup struct {
		path    string
		id      string
		label   string
		section string
	}
	groups := []containerGroup{
		{path: "containers", id: "container", label: "Container", section: "containers"},
		{path: "initContainers", id: "initContainer", label: "Init Container", section: "containers"},
		{path: "ephemeralContainers", id: "ephemeralContainer", label: "Ephemeral Container", section: "containers"},
	}
	result := make([]SummaryField, 0)
	remainingContainers := maximumSummaryContainers
	remainingPorts := maximumSummaryPorts
	omittedContainers := 0
	seenContainers := make(map[string]struct{})
	seenPorts := make(map[string]struct{})
	for _, group := range groups {
		containers, found, err := unstructured.NestedSlice(object, "spec", group.path)
		if err != nil || !found {
			continue
		}
		if len(containers) > remainingContainers {
			omittedContainers += len(containers) - remainingContainers
			containers = containers[:remainingContainers]
		}
		remainingContainers -= len(containers)
		for _, raw := range containers {
			container, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			name, _, _ := unstructured.NestedString(container, "name")
			if !validSummaryToken(name, maximumSummaryNameBytes) {
				continue
			}
			containerID := group.id + ":" + name
			if _, duplicate := seenContainers[containerID]; !duplicate {
				seenContainers[containerID] = struct{}{}
				result = append(result, SummaryField{
					Section: group.section, ID: containerID, Label: group.label, Value: name,
				})
			}
			if remainingPorts == 0 {
				continue
			}
			ports, found, err := unstructured.NestedSlice(container, "ports")
			if err != nil || !found {
				continue
			}
			if len(ports) > remainingPorts {
				ports = ports[:remainingPorts]
			}
			remainingPorts -= len(ports)
			for _, rawPort := range ports {
				port, ok := rawPort.(map[string]any)
				if !ok {
					continue
				}
				number, found, _ := unstructured.NestedInt64(port, "containerPort")
				if !found || number <= 0 {
					continue
				}
				portName, _, _ := unstructured.NestedString(port, "name")
				if portName != "" && !validSummaryToken(portName, maximumSummaryPortNameBytes) {
					continue
				}
				protocol := summaryProtocol(port)
				portID := fmt.Sprintf("port:%s:%d:%s", protocol, number, portName)
				if _, duplicate := seenPorts[portID]; duplicate {
					continue
				}
				seenPorts[portID] = struct{}{}
				display := fmt.Sprintf("%d/%s", number, protocol)
				if portName != "" {
					display = portName + ": " + display
				}
				result = append(result, SummaryField{
					Section: "ports", ID: portID,
					Label: name + " Port", Value: display,
				})
			}
		}
	}
	if omittedContainers > 0 {
		result = append(result, omittedSummaryField(
			"containers", "containersOmitted", "Containers", omittedContainers,
		))
	}
	return result
}

func servicePortSummary(object map[string]any) []SummaryField {
	ports, found, err := unstructured.NestedSlice(object, "spec", "ports")
	if err != nil || !found {
		return nil
	}
	if len(ports) > maximumSummaryPorts {
		ports = ports[:maximumSummaryPorts]
	}
	result := make([]SummaryField, 0, len(ports))
	seen := make(map[string]struct{})
	for _, raw := range ports {
		port, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		number, found, _ := unstructured.NestedInt64(port, "port")
		if !found || number <= 0 {
			continue
		}
		name, _, _ := unstructured.NestedString(port, "name")
		if name != "" && !validSummaryToken(name, maximumSummaryPortNameBytes) {
			continue
		}
		protocol := summaryProtocol(port)
		fieldID := fmt.Sprintf("port:%s:%d:%s", protocol, number, name)
		if _, duplicate := seen[fieldID]; duplicate {
			continue
		}
		seen[fieldID] = struct{}{}
		display := fmt.Sprintf("%d/%s", number, protocol)
		if name != "" {
			display = name + ": " + display
		}
		if target, found, _ := unstructured.NestedString(port, "targetPort"); found &&
			validSummaryToken(target, maximumSummaryPortNameBytes) {
			display += " → " + target
		} else if target, found, _ := unstructured.NestedInt64(port, "targetPort"); found && target > 0 {
			display += fmt.Sprintf(" → %d", target)
		}
		result = append(result, SummaryField{
			Section: "ports", ID: fieldID, Label: "Port", Value: display,
		})
	}
	return result
}

func summaryProtocol(port map[string]any) string {
	protocol, _, _ := unstructured.NestedString(port, "protocol")
	switch strings.ToUpper(protocol) {
	case "UDP":
		return "UDP"
	case "SCTP":
		return "SCTP"
	default:
		return "TCP"
	}
}

func omittedSummaryField(section, id, label string, count int) SummaryField {
	return SummaryField{
		Section: section, ID: id, Label: "Additional " + label,
		Value: fmt.Sprintf("%d not shown", count),
	}
}

func boundedSummaryLabel(value string) string {
	return boundedNormalizedText(value, maximumSummaryLabelBytes)
}

func boundedSummaryText(value string) string {
	return boundedNormalizedText(value, maximumSummaryValueBytes)
}

func boundedNormalizedText(value string, maximumBytes int) string {
	value = strings.Map(func(current rune) rune {
		if unicode.IsSpace(current) {
			return ' '
		}
		if unicode.IsControl(current) {
			return -1
		}
		return current
	}, strings.ToValidUTF8(value, "�"))
	value = strings.Join(strings.Fields(value), " ")
	if len(value) <= maximumBytes {
		return value
	}
	const suffix = "…"
	end := maximumBytes - len(suffix)
	for end > 0 && !utf8.RuneStart(value[end]) {
		end--
	}
	return value[:end] + suffix
}

func validSummaryToken(value string, maximumBytes int) bool {
	if value == "" || len(value) > maximumBytes || strings.ContainsRune(value, ':') {
		return false
	}
	for _, current := range value {
		if current < 0x21 || current > 0x7e {
			return false
		}
	}
	return true
}

func cloneStrings(value map[string]string) map[string]string {
	if value == nil {
		return nil
	}
	result := make(map[string]string, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}

func valueOrDash(value string) string {
	if value == "" {
		return "—"
	}
	return value
}
