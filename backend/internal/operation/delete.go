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
	deleteSelectionPageSize  = 256
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

// DeleteTargetPageSource resolves one bounded slice of an immutable target
// set. Offset is a rank in that set. Implementations must keep already
// accepted sources valid until the operation releases them.
type DeleteTargetPageSource interface {
	Page(offset uint64, limit uint32) ([]DeleteTarget, error)
}

// AggregateDeleteProgress reports a lazily resolved target without assigning
// it a dense manager index.
type AggregateDeleteProgress func(target DeleteTarget, state ItemState, result DeleteResult) bool

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

// DeletePagedWithProgress consumes an immutable selection in bounded pages
// and keeps at most O(page size + concurrency) target identities live. Exact
// UID preconditions are applied by the same per-target path as explicit bulk
// deletion.
func DeletePagedWithProgress(
	ctx context.Context,
	client DeleteResourceProvider,
	total uint32,
	source DeleteTargetPageSource,
	options DeleteOptions,
	progress AggregateDeleteProgress,
) error {
	if ctx == nil {
		return errors.New("delete context is nil")
	}
	if client == nil {
		return errors.New("delete resource client is nil")
	}
	if source == nil {
		return errors.New("delete target source is nil")
	}
	if total == 0 {
		return errors.New("delete target source is empty")
	}
	if err := validateDeleteOptions(options); err != nil {
		return err
	}

	concurrency := options.MaxConcurrency
	if concurrency <= 0 {
		concurrency = DefaultDeleteConcurrency
	}
	concurrency = min(concurrency, MaxDeleteConcurrency, int(total))
	workContext, cancelWork := context.WithCancelCause(ctx)
	defer cancelWork(context.Canceled)
	jobs := make(chan DeleteTarget, concurrency)
	var workers sync.WaitGroup
	workers.Add(concurrency)
	for range concurrency {
		go func() {
			defer workers.Done()
			for target := range jobs {
				result := DeleteResult{Target: target}
				if err := context.Cause(workContext); err != nil {
					result.Err = err
					reportAggregateDelete(progress, target, ItemStateCancelled, result)
					continue
				}
				if err := validateTarget(target); err != nil {
					result.Err = err
					reportAggregateDelete(progress, target, ItemStateFailed, result)
					continue
				}
				resource, err := client.Resource(target.Identity)
				if err != nil {
					result.Err = err
					reportAggregateDelete(progress, target, ItemStateFailed, result)
					continue
				}
				if !reportAggregateDelete(progress, target, ItemStateRunning, result) {
					err := context.Cause(workContext)
					if err == nil {
						err = context.Canceled
					}
					result.Err = err
					reportAggregateDelete(progress, target, ItemStateCancelled, result)
					continue
				}
				uid := types.UID(target.Identity.UID)
				err = resource.Delete(workContext, target.Identity.Name, metav1.DeleteOptions{
					GracePeriodSeconds: options.GracePeriodSeconds,
					PropagationPolicy:  &options.PropagationPolicy,
					Preconditions:      &metav1.Preconditions{UID: &uid},
				})
				result.Err = err
				state := ItemStateSucceeded
				if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					state = ItemStateCancelled
				} else if err != nil {
					state = ItemStateFailed
				}
				reportAggregateDelete(progress, target, state, result)
			}
		}()
	}

	var producerErr error
produce:
	for offset := uint64(0); offset < uint64(total); {
		if err := context.Cause(workContext); err != nil {
			producerErr = err
			break
		}
		remaining := uint64(total) - offset
		limit := uint32(min(remaining, uint64(deleteSelectionPageSize)))
		page, err := source.Page(offset, limit)
		if err != nil {
			producerErr = err
			cancelWork(err)
			break
		}
		if len(page) == 0 || len(page) > int(limit) {
			producerErr = fmt.Errorf(
				"delete target source returned %d items at offset %d with limit %d",
				len(page), offset, limit,
			)
			cancelWork(producerErr)
			break
		}
		for _, target := range page {
			if err := context.Cause(workContext); err != nil {
				producerErr = err
				break produce
			}
			select {
			case jobs <- target:
				offset++
			case <-workContext.Done():
				producerErr = context.Cause(workContext)
				break produce
			}
		}
	}
	close(jobs)
	workers.Wait()
	if producerErr != nil {
		return producerErr
	}
	return context.Cause(workContext)
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

func reportAggregateDelete(
	progress AggregateDeleteProgress,
	target DeleteTarget,
	state ItemState,
	result DeleteResult,
) bool {
	if progress == nil {
		return true
	}
	return progress(target, state, result)
}
