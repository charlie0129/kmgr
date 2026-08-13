package object

import (
	"context"
	"errors"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/watch"
)

var ErrObjectWatchClosed = errors.New("Kubernetes object watch closed unexpectedly")

// Watch opens a server-side watch restricted to the selected namespace/name.
// The UID is checked on every delivered object by the gRPC adapter, because a
// field selector cannot distinguish a same-name recreation.
func (r *Reader) Watch(
	ctx context.Context,
	identity Identity,
	resourceVersion string,
) (watch.Interface, error) {
	resource, err := r.Resource(identity)
	if err != nil {
		return nil, err
	}
	return resource.Watch(ctx, metav1.ListOptions{
		AllowWatchBookmarks: true,
		FieldSelector:       fields.OneTermEqualSelector("metadata.name", identity.Name).String(),
		ResourceVersion:     resourceVersion,
	})
}
