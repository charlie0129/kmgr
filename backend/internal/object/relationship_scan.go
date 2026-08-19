package object

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"sort"
	"strings"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/metadata"
)

const (
	relationshipScanPageSize     int64  = 500
	maxRelationshipScanResources        = 512
	maxRelationshipScanObjects   uint64 = 250_000
	maxRelationshipScanMatches          = 10_000
)

var ErrRelationshipScanLimit = errors.New("relationship scan safety limit reached")

type RelationshipScanResolver interface {
	RelationshipScanSession(sessionID string) (RelationshipScanSession, error)
}

// RelationshipScanSession exposes the authority-shared discovery catalog and
// the metadata client used for the explicit object scan. It deliberately does
// not expose a raw discovery client, which would let callers bypass catalog
// reuse and repeat the complete API group/version fanout.
type RelationshipScanSession interface {
	DiscoverResources(context.Context) (cluster.ResourceDiscovery, error)
	Metadata() metadata.Interface
}

type RelationshipScanResource struct {
	Group      string
	Version    string
	Resource   string
	Kind       string
	Namespaced bool
}

func (r RelationshipScanResource) GVR() schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: r.Group, Version: r.Version, Resource: r.Resource}
}

type RelationshipScanProgress struct {
	ResourcesTotal        int
	ResourcesScanned      int
	ObjectsExamined       uint64
	ResourcesFailed       int
	Current               RelationshipScanResource
	Complete              bool
	PotentiallyIncomplete bool
}

type RelationshipScanUpdate struct {
	Relationships []Relationship
	Progress      RelationshipScanProgress
	Warning       error
}

// ScanRelationships performs an explicit, read-only scan of one preferred
// served version of each discovered listable resource. Resources and pages are
// processed sequentially, keeping API pressure and memory bounded. Matching is
// exclusively by the selected owner's UID.
func (r *Reader) ScanRelationships(
	ctx context.Context,
	identity Identity,
	emit func(RelationshipScanUpdate) error,
) error {
	if emit == nil {
		return errors.New("relationship scan emitter must not be nil")
	}
	resolver, ok := r.resolver.(RelationshipScanResolver)
	if !ok {
		return ErrRelationshipResolutionUnavailable
	}
	session, err := resolver.RelationshipScanSession(identity.SessionID)
	if err != nil {
		return err
	}
	if session == nil {
		return ErrRelationshipResolutionUnavailable
	}
	metadataClient := session.Metadata()
	if metadataClient == nil {
		return ErrRelationshipResolutionUnavailable
	}
	// Anchor the entire scan to the exact selected UID before discovery or any
	// bulk LIST. A metadata GET is sufficient, and a recreated same-name object
	// fails here rather than being adopted by the scan.
	resource := metadataClient.Resource(identity.GVR())
	var selected metadata.ResourceInterface = resource
	if identity.Namespace != "" {
		selected = resource.Namespace(identity.Namespace)
	}
	if _, err := getIdentityMetadata(ctx, selected, identity); err != nil {
		return err
	}
	resources, discoveryIncomplete, err := discoverRelationshipResources(ctx, session)
	if err != nil {
		return err
	}
	resources = applicableRelationshipResources(resources, identity.Namespace)
	if len(resources) > maxRelationshipScanResources {
		return fmt.Errorf("%w: discovery returned %d applicable resources (limit %d)",
			ErrRelationshipScanLimit, len(resources), maxRelationshipScanResources)
	}
	progress := RelationshipScanProgress{
		ResourcesTotal: len(resources), PotentiallyIncomplete: discoveryIncomplete,
	}
	if err := emit(RelationshipScanUpdate{Progress: progress}); err != nil {
		return err
	}

	seen := make(map[string]struct{})
	for _, resource := range resources {
		if err := ctx.Err(); err != nil {
			return err
		}
		progress.Current = resource
		resourceErr := r.scanRelationshipResource(
			ctx, metadataClient, identity, resource, seen, &progress, emit,
		)
		progress.ResourcesScanned++
		if resourceErr != nil {
			if errors.Is(resourceErr, context.Canceled) || errors.Is(resourceErr, context.DeadlineExceeded) ||
				errors.Is(resourceErr, ErrRelationshipScanLimit) {
				return resourceErr
			}
			progress.ResourcesFailed++
			progress.PotentiallyIncomplete = true
			if err := emit(RelationshipScanUpdate{Progress: progress, Warning: resourceErr}); err != nil {
				return err
			}
			continue
		}
		if err := emit(RelationshipScanUpdate{Progress: progress}); err != nil {
			return err
		}
	}
	progress.Current = RelationshipScanResource{}
	progress.Complete = true
	return emit(RelationshipScanUpdate{Progress: progress})
}

func (r *Reader) scanRelationshipResource(
	ctx context.Context,
	metadataClient metadata.Interface,
	owner Identity,
	resource RelationshipScanResource,
	seen map[string]struct{},
	progress *RelationshipScanProgress,
	emit func(RelationshipScanUpdate) error,
) error {
	getter := metadataClient.Resource(resource.GVR())
	var client metadata.ResourceInterface = getter
	if resource.Namespaced && owner.Namespace != "" {
		client = getter.Namespace(owner.Namespace)
	}
	continueToken := ""
	seenTokens := make(map[string]struct{})
	for {
		page, err := client.List(ctx, metav1.ListOptions{
			Limit: relationshipScanPageSize, Continue: continueToken,
		})
		if err != nil {
			return fmt.Errorf("list %s: %w", resource.GVR().String(), err)
		}
		progress.ObjectsExamined += uint64(len(page.Items))
		if progress.ObjectsExamined > maxRelationshipScanObjects {
			return fmt.Errorf("%w: examined more than %d objects", ErrRelationshipScanLimit, maxRelationshipScanObjects)
		}
		matches := make([]Relationship, 0)
		for index := range page.Items {
			value := &page.Items[index]
			if value.GetUID() == "" || !hasOwnerUID(value.GetOwnerReferences(), owner.UID) {
				continue
			}
			key := strings.Join([]string{
				resource.Group, resource.Version, resource.Resource, string(value.GetUID()),
			}, "\x00")
			if _, exists := seen[key]; exists {
				continue
			}
			if len(seen) >= maxRelationshipScanMatches {
				return fmt.Errorf("%w: found more than %d child relationships", ErrRelationshipScanLimit, maxRelationshipScanMatches)
			}
			seen[key] = struct{}{}
			matches = append(matches, Relationship{
				Kind: RelationshipChild,
				Identity: Identity{
					SessionID: owner.SessionID, Group: resource.Group, Version: resource.Version,
					Resource: resource.Resource, Namespace: value.GetNamespace(),
					Name: value.GetName(), UID: string(value.GetUID()),
				},
				Label: resource.Kind,
			})
		}
		if len(matches) != 0 {
			if err := emit(RelationshipScanUpdate{
				Relationships: sortedRelationships(matches), Progress: *progress,
			}); err != nil {
				return err
			}
		}
		next := page.GetContinue()
		if next == "" {
			return nil
		}
		if next == continueToken {
			return fmt.Errorf("list %s returned a repeated continue token", resource.GVR().String())
		}
		if _, exists := seenTokens[next]; exists {
			return fmt.Errorf("list %s returned a cyclic continue token", resource.GVR().String())
		}
		seenTokens[next] = struct{}{}
		continueToken = next
	}
}

func discoverRelationshipResources(
	ctx context.Context,
	session RelationshipScanSession,
) ([]RelationshipScanResource, bool, error) {
	if session == nil {
		return nil, false, ErrRelationshipResolutionUnavailable
	}
	discovered, err := session.DiscoverResources(ctx)
	if err != nil {
		return nil, false, fmt.Errorf("discover listable resources: %w", err)
	}
	preferred := make(map[string]string)
	for _, value := range discovered.Resources {
		if value.PreferredVersion {
			preferred[value.Group] = value.Version
		}
	}
	chosen := make(map[string]RelationshipScanResource)
	for _, value := range discovered.Resources {
		candidate := RelationshipScanResource{
			Group: value.Group, Version: value.Version, Resource: value.Resource,
			Kind: value.Kind, Namespaced: value.Namespaced,
		}
		key := value.Group + "\x00" + value.Resource
		current, exists := chosen[key]
		candidatePreferred := preferred[value.Group] == value.Version
		currentPreferred := preferred[current.Group] == current.Version
		if !exists || (candidatePreferred && !currentPreferred) ||
			(candidatePreferred == currentPreferred && candidate.Version < current.Version) {
			chosen[key] = candidate
		}
	}
	result := make([]RelationshipScanResource, 0, len(chosen))
	for _, resource := range chosen {
		result = append(result, resource)
	}
	sort.Slice(result, func(i, j int) bool {
		return strings.Join([]string{result[i].Group, result[i].Resource, result[i].Version}, "\x00") <
			strings.Join([]string{result[j].Group, result[j].Resource, result[j].Version}, "\x00")
	})
	return result, discovered.PotentiallyIncomplete, nil
}

func applicableRelationshipResources(
	values []RelationshipScanResource,
	ownerNamespace string,
) []RelationshipScanResource {
	if ownerNamespace == "" {
		return values
	}
	return slices.DeleteFunc(values, func(value RelationshipScanResource) bool { return !value.Namespaced })
}
