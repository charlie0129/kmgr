// Package systemmemory resolves conservative byte budgets from host physical
// memory. Platform-specific discovery is deliberately kept behind Bytes so
// callers and tests can exercise the overflow-sensitive arithmetic directly.
package systemmemory

import (
	"errors"
	"fmt"
	"math"
)

// PercentageLimit returns percent of totalBytes as a positive signed byte
// count. Dividing before multiplying avoids overflowing uint64 even when a
// test or future platform reports a value near its representable maximum.
func PercentageLimit(totalBytes uint64, percent int) (int64, error) {
	if totalBytes == 0 {
		return 0, errors.New("physical memory must be positive")
	}
	if percent < 1 || percent > 100 {
		return 0, fmt.Errorf("memory percentage must be between 1 and 100, got %d", percent)
	}

	percentage := uint64(percent)
	whole := (totalBytes / 100) * percentage
	fraction := ((totalBytes % 100) * percentage) / 100
	limit := whole + fraction
	if limit == 0 {
		return 0, errors.New("physical-memory percentage produced a zero-byte limit")
	}
	if limit > math.MaxInt64 {
		return 0, fmt.Errorf("physical-memory percentage exceeds the maximum signed byte limit: %d", limit)
	}
	return int64(limit), nil
}
