//go:build !darwin && !linux

package systemmemory

import (
	"fmt"
	"runtime"
)

// Bytes fails explicitly on unsupported hosts instead of silently treating
// process address space or an arbitrary fixed number as physical memory.
func Bytes() (uint64, error) {
	return 0, fmt.Errorf("physical-memory discovery is unsupported on %s", runtime.GOOS)
}
