//go:build darwin

package systemmemory

import (
	"fmt"

	"golang.org/x/sys/unix"
)

// Bytes returns the physical memory installed in the host.
func Bytes() (uint64, error) {
	total, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		return 0, fmt.Errorf("read physical memory: %w", err)
	}
	if total == 0 {
		return 0, fmt.Errorf("read physical memory: host reported zero bytes")
	}
	return total, nil
}
