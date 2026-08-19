package execstream

import (
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"
)

type ResolverFunc func(string) (ResolvedSession, error)

func (f ResolverFunc) Resolve(sessionID string) (ResolvedSession, error) {
	return f(sessionID)
}

type ExecutorFactoryFunc func(*rest.Config, string, func()) (remotecommand.Executor, error)

func (f ExecutorFactoryFunc) New(
	config *rest.Config,
	requestURL string,
	ready func(),
) (remotecommand.Executor, error) {
	return f(config, requestURL, ready)
}
