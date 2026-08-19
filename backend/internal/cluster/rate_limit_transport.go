package cluster

import (
	"net/http"
	"strings"

	"k8s.io/client-go/rest"
	"k8s.io/client-go/util/flowcontrol"
)

// configWithSupplementalRateLimit closes the gaps left by client-go's normal
// request throttling. client-go intentionally skips its RateLimiter when it
// opens a WATCH, and streaming upgrade transports do not consult the limiter
// at all. Ordinary REST requests are deliberately excluded here because their
// rest.Request already consumes one token from this same authority-wide
// limiter.
func configWithSupplementalRateLimit(config *rest.Config) *rest.Config {
	config = rest.CopyConfig(config)
	limiter := config.RateLimiter
	if limiter == nil {
		return config
	}
	previous := config.WrapTransport
	config.WrapTransport = func(base http.RoundTripper) http.RoundTripper {
		if previous != nil {
			base = previous(base)
		}
		return &supplementalRateLimitRoundTripper{base: base, limiter: limiter}
	}
	return config
}

type supplementalRateLimitRoundTripper struct {
	base    http.RoundTripper
	limiter flowcontrol.RateLimiter
}

func (t *supplementalRateLimitRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	if requiresSupplementalRateLimit(request) {
		if err := t.limiter.Wait(request.Context()); err != nil {
			if request.Body != nil {
				_ = request.Body.Close()
			}
			return nil, err
		}
	}
	return t.base.RoundTrip(request)
}

func requiresSupplementalRateLimit(request *http.Request) bool {
	if request == nil || request.URL == nil {
		return false
	}
	if request.URL.Query().Get("watch") == "true" {
		return true
	}
	path := strings.TrimRight(request.URL.Path, "/")
	separator := strings.LastIndexByte(path, '/')
	if separator >= 0 {
		path = path[separator+1:]
	}
	return path == "exec" || path == "portforward"
}
