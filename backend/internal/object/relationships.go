package object

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

var ErrRelationshipResolutionUnavailable = errors.New("Kubernetes relationship resolution is unavailable")

type RelationshipKind uint8

const (
	RelationshipOwner RelationshipKind = iota + 1
	RelationshipChild
	RelationshipRelated
)

type Relationship struct {
	Kind                  RelationshipKind
	Identity              Identity
	Label                 string
	Stale                 bool
	PotentiallyIncomplete bool
}

type CachedChild struct {
	Group    string
	Version  string
	Resource string
	Object   *unstructured.Unstructured
}

// CachedChildSource is implemented by the resource view runtime. The returned
// values are a point-in-time snapshot from only active/warm stores and never
// imply exhaustive cluster coverage.
type CachedChildSource interface {
	CachedChildren(sessionID, ownerUID string) []CachedChild
}

// CachedChildSnapshot is the structural representation used by the view
// runtime. Keeping the interface in object avoids an object/view import cycle.
// Implementations may return this concrete slice through an adapter.

type KindResolver interface {
	ResourceForKind(
		ctx context.Context,
		sessionID string,
		gvk schema.GroupVersionKind,
		namespace string,
	) (dynamic.ResourceInterface, schema.GroupVersionResource, string, error)
}

// Relationships first fresh-GETs the selected identity, preserving exact UID
// semantics. Owners are REST-mapped and verified authoritatively. Children are
// drawn only from existing view caches, so every cached child and the overall
// child result are explicitly marked potentially incomplete.
func (r *Reader) Relationships(
	ctx context.Context,
	identity Identity,
	includeOwners, includeChildren bool,
) ([]Relationship, bool, error) {
	value, err := r.Get(ctx, identity)
	if err != nil {
		return nil, false, err
	}
	result := make([]Relationship, 0)
	if includeOwners {
		owners, err := r.ownerRelationships(ctx, identity, value)
		if err != nil {
			return nil, false, err
		}
		result = append(result, owners...)
	}
	childrenIncomplete := includeChildren
	if includeChildren && r.cachedChildren != nil {
		for _, child := range r.cachedChildren.CachedChildren(identity.SessionID, identity.UID) {
			if child.Object == nil || child.Object.GetUID() == "" ||
				!hasOwnerUID(child.Object.GetOwnerReferences(), identity.UID) {
				continue
			}
			result = append(result, Relationship{
				Kind: RelationshipChild,
				Identity: Identity{
					SessionID: identity.SessionID, Group: child.Group, Version: child.Version,
					Resource: child.Resource, Namespace: child.Object.GetNamespace(),
					Name: child.Object.GetName(), UID: string(child.Object.GetUID()),
				},
				Label: child.Object.GetKind(), PotentiallyIncomplete: true,
			})
		}
	}
	return sortedRelationships(deduplicateRelationships(result)), childrenIncomplete, nil
}

func (r *Reader) ownerRelationships(
	ctx context.Context,
	identity Identity,
	value *unstructured.Unstructured,
) ([]Relationship, error) {
	resolver, ok := r.resolver.(KindResolver)
	if !ok {
		return nil, ErrRelationshipResolutionUnavailable
	}
	owners := value.GetOwnerReferences()
	result := make([]Relationship, 0, len(owners))
	for _, owner := range owners {
		gvk := schema.FromAPIVersionAndKind(owner.APIVersion, owner.Kind)
		if gvk.Version == "" || gvk.Kind == "" || owner.Name == "" || owner.UID == "" {
			return nil, fmt.Errorf("invalid owner reference on %s/%s", identity.Namespace, identity.Name)
		}
		resource, gvr, namespace, err := resolver.ResourceForKind(
			ctx, identity.SessionID, gvk, identity.Namespace,
		)
		if err != nil {
			return nil, err
		}
		ownerIdentity := Identity{
			SessionID: identity.SessionID, Group: gvr.Group, Version: gvr.Version,
			Resource: gvr.Resource, Namespace: namespace, Name: owner.Name, UID: string(owner.UID),
		}
		stale := false
		current, err := resource.Get(ctx, owner.Name, metav1.GetOptions{})
		switch {
		case err == nil:
			stale = string(current.GetUID()) != string(owner.UID)
		case apierrors.IsNotFound(err):
			stale = true
		default:
			return nil, err
		}
		result = append(result, Relationship{
			Kind: RelationshipOwner, Identity: ownerIdentity, Label: owner.Kind, Stale: stale,
		})
	}
	return result, nil
}

func hasOwnerUID(owners []metav1.OwnerReference, uid string) bool {
	for _, owner := range owners {
		if string(owner.UID) == uid {
			return true
		}
	}
	return false
}

func deduplicateRelationships(values []Relationship) []Relationship {
	seen := make(map[string]struct{}, len(values))
	result := make([]Relationship, 0, len(values))
	for _, value := range values {
		key := strings.Join([]string{
			fmt.Sprint(value.Kind), value.Identity.Group, value.Identity.Version,
			value.Identity.Resource, value.Identity.UID,
		}, "\x00")
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		result = append(result, value)
	}
	return result
}

func sortedRelationships(values []Relationship) []Relationship {
	sort.Slice(values, func(i, j int) bool {
		left, right := values[i], values[j]
		return strings.Join([]string{
			fmt.Sprintf("%02d", left.Kind), left.Identity.Group, left.Identity.Version,
			left.Identity.Resource, left.Identity.Namespace, left.Identity.Name, left.Identity.UID,
		}, "\x00") < strings.Join([]string{
			fmt.Sprintf("%02d", right.Kind), right.Identity.Group, right.Identity.Version,
			right.Identity.Resource, right.Identity.Namespace, right.Identity.Name, right.Identity.UID,
		}, "\x00")
	})
	return values
}
