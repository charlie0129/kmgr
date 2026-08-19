package portforward

import (
	"context"

	"k8s.io/apimachinery/pkg/types"
)

type BackoffFunc func(context.Context, int) error

func (f BackoffFunc) Wait(ctx context.Context, attempt int) error { return f(ctx, attempt) }

type podUIDGetterFunc func(context.Context, string, string) (types.UID, error)

func (f podUIDGetterFunc) PodUID(
	ctx context.Context,
	namespace, name string,
) (types.UID, error) {
	return f(ctx, namespace, name)
}
