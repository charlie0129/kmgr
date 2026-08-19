//go:build linux

package systemmemory

import (
	"fmt"
	"math"

	"golang.org/x/sys/unix"
)

// Bytes returns the physical memory installed in the host.
func Bytes() (uint64, error) {
	var information unix.Sysinfo_t
	if err := unix.Sysinfo(&information); err != nil {
		return 0, fmt.Errorf("read physical memory: %w", err)
	}
	total := uint64(information.Totalram)
	unit := uint64(information.Unit)
	if unit == 0 {
		unit = 1
	}
	if total == 0 {
		return 0, fmt.Errorf("read physical memory: host reported zero bytes")
	}
	if total > math.MaxUint64/unit {
		return 0, fmt.Errorf("read physical memory: byte count overflow")
	}
	return total * unit, nil
}
