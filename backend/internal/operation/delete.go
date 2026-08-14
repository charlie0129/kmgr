// Package operation implements Kubernetes mutations with explicit safety
// preconditions and bounded concurrency.
package operation

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/charlie0129/kmgr/backend/internal/object"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
)

const (
	DefaultDeleteConcurrency = 4
	MaxDeleteConcurrency     = 16
)

type DeleteTarget struct {
	Identity object.Identity
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

type DeleteResourceProvider interface {
	Resource(object.Identity) (dynamic.ResourceInterface, error)
}

// DeleteProgress reports state transitions and atomically claims work when
// state is ItemStateRunning. Returning false rejects that claim, so no
// Kubernetes request is dispatched for the item.
type DeleteProgress func(index int, state ItemState, result DeleteResult) bool

// DeleteMany captures exact identities before execution and applies UID
// preconditions to every request. Cancellation prevents not-yet-started work;
// already dispatched destructive requests are never retried automatically.
func DeleteMany(
	ctx context.Context,
	client DeleteResourceProvider,
	targets []DeleteTarget,
	options DeleteOptions,
) []DeleteResult {
	return DeleteManyWithProgress(ctx, client, targets, options, nil)
}

func DeleteManyWithProgress(
	ctx context.Context,
	client DeleteResourceProvider,
	targets []DeleteTarget,
	options DeleteOptions,
	progress DeleteProgress,
) []DeleteResult {
	results := make([]DeleteResult, len(targets))
	for index, target := range targets {
		results[index].Target = target
	}
	if len(targets) == 0 {
		return results
	}
	if client == nil {
		return failAllDeletes(results, errors.New("delete resource client is nil"), progress)
	}
	if err := validateDeleteOptions(options); err != nil {
		return failAllDeletes(results, err, progress)
	}

	concurrency := options.MaxConcurrency
	if concurrency <= 0 {
		concurrency = DefaultDeleteConcurrency
	}
	concurrency = min(concurrency, MaxDeleteConcurrency, max(1, len(targets)))

	jobs := make(chan int)
	var workers sync.WaitGroup
	workers.Add(concurrency)
	for range concurrency {
		go func() {
			defer workers.Done()
			for index := range jobs {
				// Receiving a job is not yet dispatching its destructive API call.
				// Recheck after handoff so cancellation wins before resolution.
				if err := context.Cause(ctx); err != nil {
					results[index].Err = err
					reportDelete(progress, index, ItemStateCancelled, results[index])
					continue
				}
				target := targets[index]
				if err := validateTarget(target); err != nil {
					results[index].Err = err
					reportDelete(progress, index, ItemStateFailed, results[index])
					continue
				}
				resource, err := client.Resource(target.Identity)
				if err != nil {
					results[index].Err = err
					reportDelete(progress, index, ItemStateFailed, results[index])
					continue
				}
				if !reportDelete(progress, index, ItemStateRunning, results[index]) {
					err := context.Cause(ctx)
					if err == nil {
						err = context.Canceled
					}
					results[index].Err = err
					reportDelete(progress, index, ItemStateCancelled, results[index])
					continue
				}
				uid := types.UID(target.Identity.UID)
				err = resource.Delete(ctx, target.Identity.Name, metav1.DeleteOptions{
					GracePeriodSeconds: options.GracePeriodSeconds,
					PropagationPolicy:  &options.PropagationPolicy,
					Preconditions:      &metav1.Preconditions{UID: &uid},
				})
				results[index].Err = err
				state := ItemStateSucceeded
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					state = ItemStateCancelled
				} else if err != nil {
					state = ItemStateFailed
				}
				reportDelete(progress, index, state, results[index])
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
				reportDelete(progress, pending, ItemStateCancelled, results[pending])
			}
			break sendLoop
		}
	}
	close(jobs)
	workers.Wait()
	return results
}

func validateTarget(target DeleteTarget) error {
	if err := target.Identity.Validate(); err != nil {
		return fmt.Errorf("invalid delete target: %w", err)
	}
	return nil
}

func validateDeleteOptions(options DeleteOptions) error {
	switch options.PropagationPolicy {
	case metav1.DeletePropagationBackground, metav1.DeletePropagationForeground, metav1.DeletePropagationOrphan:
	default:
		return errors.New("delete propagation policy is invalid")
	}
	if options.GracePeriodSeconds != nil && *options.GracePeriodSeconds < 0 {
		return errors.New("delete grace period must not be negative")
	}
	return nil
}

func failAllDeletes(results []DeleteResult, err error, progress DeleteProgress) []DeleteResult {
	for index := range results {
		results[index].Err = err
		reportDelete(progress, index, ItemStateFailed, results[index])
	}
	return results
}

func reportDelete(progress DeleteProgress, index int, state ItemState, result DeleteResult) bool {
	if progress == nil {
		return true
	}
	return progress(index, state, result)
}
