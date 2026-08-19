package logs

type ResolverFunc func(string) (ResolvedSession, error)

func (f ResolverFunc) Resolve(sessionID string) (ResolvedSession, error) {
	return f(sessionID)
}
