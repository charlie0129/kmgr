// Package podidentity provides fresh, metadata-only Pod identity reads for
// namespace/name streaming subresources that cannot carry UID preconditions.
package podidentity

import (
	"context"
	"errors"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/metadata"
)

var ErrUnavailable = errors.New("Kubernetes Pod metadata client is unavailable")

var podResource = schema.GroupVersionResource{Version: "v1", Resource: "pods"}

// Getter performs one fresh Pod metadata GET and returns only its UID.
type Getter interface {
	PodUID(context.Context, string, string) (types.UID, error)
}

// MetadataGetter uses client-go's PartialObjectMetadata negotiation. It keeps
// the authority's shared transport, rate limiter, credentials, and RBAC GET
// semantics while avoiding a complete Pod payload.
type MetadataGetter struct {
	Client metadata.Interface
}

func (g MetadataGetter) PodUID(
	ctx context.Context,
	namespace, name string,
) (types.UID, error) {
	if g.Client == nil {
		return "", ErrUnavailable
	}
	value, err := g.Client.Resource(podResource).Namespace(namespace).Get(
		ctx, name, metav1.GetOptions{},
	)
	if err != nil {
		return "", err
	}
	if value == nil {
		return "", errors.New("Kubernetes Pod metadata GET returned no object")
	}
	return value.GetUID(), nil
}
