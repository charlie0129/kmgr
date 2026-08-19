package systemmemory

import (
	"math"
	"runtime"
	"testing"
)

func TestPercentageLimitIsOverflowSafe(t *testing.T) {
	t.Parallel()
	checks := []struct {
		total   uint64
		percent int
		want    int64
	}{
		{total: 16 << 30, percent: 20, want: 3_435_973_836},
		{total: 101, percent: 20, want: 20},
		{total: math.MaxUint64, percent: 20, want: 3_689_348_814_741_910_323},
	}
	for _, check := range checks {
		got, err := PercentageLimit(check.total, check.percent)
		if err != nil || got != check.want {
			t.Errorf("PercentageLimit(%d, %d) = %d, %v; want %d", check.total, check.percent, got, err, check.want)
		}
	}
}

func TestPercentageLimitRejectsInvalidOrUnrepresentableBudgets(t *testing.T) {
	t.Parallel()
	for _, check := range []struct {
		total   uint64
		percent int
	}{
		{total: 0, percent: 20},
		{total: 100, percent: 0},
		{total: 100, percent: 101},
		{total: math.MaxUint64, percent: 100},
	} {
		if got, err := PercentageLimit(check.total, check.percent); err == nil || got != 0 {
			t.Errorf("PercentageLimit(%d, %d) = %d, %v; want rejection", check.total, check.percent, got, err)
		}
	}
}

func TestPhysicalMemoryIsPositiveOnSupportedHost(t *testing.T) {
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		t.Skip("physical-memory discovery is intentionally unsupported on this host")
	}
	total, err := Bytes()
	if err != nil {
		t.Fatal(err)
	}
	if total == 0 {
		t.Fatal("physical memory is zero")
	}
}
