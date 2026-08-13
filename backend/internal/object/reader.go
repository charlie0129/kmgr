// Package object implements fresh, UID-authoritative Kubernetes object reads.
// Table views retain raw objects in Go, while this package exposes full YAML or
// sensitive key/value bytes only after an explicit detail request.
package object

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"slices"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
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

type Reader struct {
	resolver Resolver
}

func NewReader(resolver Resolver) (*Reader, error) {
	if resolver == nil {
		return nil, errors.New("object resolver must not be nil")
	}
	return &Reader{resolver: resolver}, nil
}

// Get always performs an API GET. Cached command-palette or view identities
// therefore cannot enable authoritative details or mutations without refresh.
func (r *Reader) Get(ctx context.Context, identity Identity) (*unstructured.Unstructured, error) {
	if err := identity.Validate(); err != nil {
		return nil, err
	}
	resource, err := r.resolver.Resource(identity.SessionID, identity.GVR(), identity.Namespace)
	if err != nil {
		return nil, err
	}
	value, err := resource.Get(ctx, identity.Name, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}
	if string(value.GetUID()) != identity.UID {
		return nil, &IdentityChangedError{
			ExpectedUID: identity.UID,
			ActualUID:   string(value.GetUID()),
			Namespace:   identity.Namespace,
			Name:        identity.Name,
		}
	}
	return value, nil
}

type Detail struct {
	Identity        Identity
	ResourceVersion string
	YAML            []byte
	Labels          map[string]string
	Annotations     map[string]string
	Summary         []SummaryField
}

type SummaryField struct {
	Section string
	ID      string
	Label   string
	Value   string
}

func (r *Reader) Detail(ctx context.Context, identity Identity, includeYAML, includeSummary bool) (Detail, error) {
	value, err := r.Get(ctx, identity)
	if err != nil {
		return Detail{}, err
	}
	detail := Detail{
		Identity:        identity,
		ResourceVersion: value.GetResourceVersion(),
		Labels:          cloneStrings(value.GetLabels()),
		Annotations:     cloneStrings(value.GetAnnotations()),
	}
	if includeYAML {
		jsonBytes, err := value.MarshalJSON()
		if err != nil {
			return Detail{}, fmt.Errorf("marshal Kubernetes object: %w", err)
		}
		detail.YAML, err = yaml.JSONToYAML(jsonBytes)
		if err != nil {
			return Detail{}, fmt.Errorf("format Kubernetes YAML: %w", err)
		}
	}
	if includeSummary {
		detail.Summary = summarize(value)
	}
	return detail, nil
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
	fields := []SummaryField{
		{Section: "identity", ID: "kind", Label: "Kind", Value: value.GetKind()},
		{Section: "identity", ID: "namespace", Label: "Namespace", Value: valueOrDash(value.GetNamespace())},
		{Section: "identity", ID: "name", Label: "Name", Value: value.GetName()},
		{Section: "identity", ID: "uid", Label: "UID", Value: string(value.GetUID())},
		{Section: "identity", ID: "resourceVersion", Label: "Resource Version", Value: value.GetResourceVersion()},
	}
	if created := value.GetCreationTimestamp(); !created.IsZero() {
		fields = append(fields, SummaryField{
			Section: "identity", ID: "created", Label: "Created", Value: created.Time.Format("2006-01-02 15:04:05Z07:00"),
		})
	}
	if phase, found, _ := unstructured.NestedString(value.Object, "status", "phase"); found && phase != "" {
		fields = append(fields, SummaryField{Section: "status", ID: "phase", Label: "Status", Value: phase})
	}
	return fields
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
