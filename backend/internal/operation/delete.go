// Package operation implements Kubernetes mutations with explicit safety
// preconditions and bounded concurrency.
package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

const DefaultDeleteConcurrency = 4

type DeleteTarget struct {
	GVR       schema.GroupVersionResource
	Namespace string
	Name      string
	UID       types.UID
}

type DeleteOptions struct {
	PropagationPolicy  metav1.DeletionPropagation
	GracePeriodSeconds *int64
	MaxConcurrency     int
}

type DeleteResult struct {
	Target DeleteTarget
	Err    error
}

type DynamicResourceProvider interface {
	Resource(schema.GroupVersionResource) dynamic.NamespaceableResourceInterface
}

// DeleteMany captures exact identities before execution and applies UID
// preconditions to every request. Cancellation prevents not-yet-started work;
// already dispatched destructive requests are never retried automatically.
func DeleteMany(
	ctx context.Context,
	client DynamicResourceProvider,
	targets []DeleteTarget,
	options DeleteOptions,
) []DeleteResult {
	results := make([]DeleteResult, len(targets))
	for index, target := range targets {
		results[index].Target = target
	}
	if client == nil {
		err := errors.New("delete resource client is nil")
		for index := range results {
			results[index].Err = err
		}
		return results
	}

	concurrency := options.MaxConcurrency
	if concurrency <= 0 {
		concurrency = DefaultDeleteConcurrency
	}
	concurrency = min(concurrency, max(1, len(targets)))

	jobs := make(chan int)
	var workers sync.WaitGroup
	workers.Add(concurrency)
	for range concurrency {
		go func() {
			defer workers.Done()
			for index := range jobs {
				target := targets[index]
				if err := validateTarget(target); err != nil {
					results[index].Err = err
					continue
				}
				resource := client.Resource(target.GVR)
				var scoped dynamic.ResourceInterface = resource
				if target.Namespace != "" {
					scoped = resource.Namespace(target.Namespace)
				}
				results[index].Err = scoped.Delete(ctx, target.Name, metav1.DeleteOptions{
					GracePeriodSeconds: options.GracePeriodSeconds,
					PropagationPolicy:  &options.PropagationPolicy,
					Preconditions:      &metav1.Preconditions{UID: &target.UID},
				})
			}
		}()
	}

sendLoop:
	for index := range targets {
		select {
		case jobs <- index:
		case <-ctx.Done():
			for pending := index; pending < len(results); pending++ {
				results[pending].Err = context.Cause(ctx)
			}
			break sendLoop
		}
	}
	close(jobs)
	workers.Wait()
	return results
}

func validateTarget(target DeleteTarget) error {
	if target.GVR.Version == "" || target.GVR.Resource == "" {
		return errors.New("delete target has incomplete GVR")
	}
	if target.Name == "" {
		return errors.New("delete target has no name")
	}
	if target.UID == "" {
		return fmt.Errorf("delete target %q has no UID precondition", target.Name)
	}
	return nil
}
