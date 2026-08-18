package view

import (
	"math"
	"strconv"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

// formatResourceQuantity keeps Kubernetes resource semantics while choosing a
// compact, consistent presentation unit. The exact canonical Quantity string
// remains available in cell tooltips; this function is only for display text.
func formatResourceQuantity(name corev1.ResourceName, quantity *resource.Quantity) string {
	if quantity == nil {
		return DefaultMissingCell
	}
	if name == corev1.ResourceCPU {
		return formatCPUQuantity(*quantity)
	}
	if isByteResource(name) {
		return formatBinaryQuantity(*quantity)
	}
	return quantity.String()
}

func isByteResource(name corev1.ResourceName) bool {
	return name == corev1.ResourceMemory || name == corev1.ResourceEphemeralStorage ||
		strings.HasPrefix(string(name), corev1.ResourceHugePagesPrefix)
}

func formatCPUQuantity(quantity resource.Quantity) string {
	cores := quantity.AsApproximateFloat64()
	// Metrics retain nanocore precision for sorting and pressure calculations,
	// but sub-millicore core fractions add visual noise to dense tables (for
	// example 0.000102). Keep this as a presentation-only threshold.
	if math.Abs(cores) < 0.001 {
		return "0"
	}
	return adaptiveDecimal(cores)
}

func formatBinaryQuantity(quantity resource.Quantity) string {
	bytes := quantity.AsApproximateFloat64()
	if bytes == 0 {
		return "0"
	}
	units := [...]struct {
		bytes  float64
		suffix string
	}{
		{bytes: 1 << 60, suffix: "Ei"},
		{bytes: 1 << 50, suffix: "Pi"},
		{bytes: 1 << 40, suffix: "Ti"},
		{bytes: 1 << 30, suffix: "Gi"},
		{bytes: 1 << 20, suffix: "Mi"},
		{bytes: 1 << 10, suffix: "Ki"},
	}
	abs := math.Abs(bytes)
	for _, unit := range units {
		if abs >= unit.bytes {
			return compactDecimal(bytes/unit.bytes, 2) + unit.suffix
		}
	}
	// A suffix-free Kubernetes quantity is a byte count. Fractional bytes are
	// unusual but valid Quantity inputs, so retain up to millibyte precision.
	return compactDecimal(bytes, 3)
}

func compactDecimal(value float64, fractionalDigits int) string {
	text := strconv.FormatFloat(value, 'f', fractionalDigits, 64)
	if strings.Contains(text, ".") {
		text = strings.TrimRight(strings.TrimRight(text, "0"), ".")
	}
	if text == "-0" {
		return "0"
	}
	return text
}

// adaptiveDecimal keeps resource cells dense with at most two fractional
// digits. Values of ten or more retain their existing one-digit presentation;
// smaller values round to two digits instead of expanding precision after
// leading fractional zeroes.
func adaptiveDecimal(value float64) string {
	if !math.IsNaN(value) && !math.IsInf(value, 0) && value == 0 {
		return "0"
	}
	fractionalDigits := 2
	if math.Abs(value) >= 10 {
		fractionalDigits = 1
	}
	return compactDecimal(value, fractionalDigits)
}
