package object

import (
	"context"
	"errors"
	"fmt"
	"sort"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

var (
	ErrRelationshipResolutionUnavailable = errors.New("Kubernetes relationship resolution is unavailable")
	ErrChildRelationshipsUnavailable     = errors.New("child relationship lookup is unavailable")
)

type RelationshipKind uint8

const (
	RelationshipOwner RelationshipKind = iota + 1
	RelationshipChild
	RelationshipRelated
)

type Relationship struct {
	Kind     RelationshipKind
	Identity Identity
	Label    string
	Stale    bool
}

type KindResolver interface {
	ResourceForKind(
		sessionID string,
		gvk schema.GroupVersionKind,
		namespace string,
	) (dynamic.ResourceInterface, schema.GroupVersionResource, string, error)
}

// Relationships resolves owner references authoritatively through the REST
// mapper and verifies each referenced UID. Child lookup needs a shared
// cross-resource owner index (or an explicitly authorized discovery scan), so
// it is rejected rather than guessed from resource-kind pluralization.
func (r *Reader) Relationships(
	ctx context.Context,
	identity Identity,
	includeOwners, includeChildren bool,
) ([]Relationship, error) {
	value, err := r.Get(ctx, identity)
	if err != nil {
		return nil, err
	}
	if includeChildren {
		return nil, ErrChildRelationshipsUnavailable
	}
	if !includeOwners {
		return nil, nil
	}
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
		resource, gvr, namespace, err := resolver.ResourceForKind(identity.SessionID, gvk, identity.Namespace)
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
	sort.Slice(result, func(i, j int) bool {
		left, right := result[i], result[j]
		if left.Label != right.Label {
			return left.Label < right.Label
		}
		if left.Identity.Namespace != right.Identity.Namespace {
			return left.Identity.Namespace < right.Identity.Namespace
		}
		if left.Identity.Name != right.Identity.Name {
			return left.Identity.Name < right.Identity.Name
		}
		return left.Identity.UID < right.Identity.UID
	})
	return result, nil
}
