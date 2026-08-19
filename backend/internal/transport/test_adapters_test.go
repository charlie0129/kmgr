package transport

import (
	"context"

	"github.com/charlie0129/kmgr/backend/internal/cluster"
)

type SessionProbeFunc func(context.Context, *cluster.Session) error

func (f SessionProbeFunc) Probe(ctx context.Context, session *cluster.Session) error {
	return f(ctx, session)
}
