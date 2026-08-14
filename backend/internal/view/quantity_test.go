package view

import (
	"testing"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

func TestFormatResourceQuantityUsesReadableSemanticUnits(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name         string
		resourceName corev1.ResourceName
		quantity     string
		want         string
	}{
		{name: "nil", resourceName: corev1.ResourceCPU, want: DefaultMissingCell},
		{name: "zero CPU", resourceName: corev1.ResourceCPU, quantity: "0", want: "0"},
		{name: "sub-core CPU", resourceName: corev1.ResourceCPU, quantity: "123400u", want: "0.12"},
		{name: "sub-millicore CPU rounds to zero", resourceName: corev1.ResourceCPU, quantity: "123u", want: "0"},
		{name: "one millicore remains visible", resourceName: corev1.ResourceCPU, quantity: "1m", want: "0.001"},
		{name: "multi-core CPU", resourceName: corev1.ResourceCPU, quantity: "12345678900n", want: "12.3"},
		{name: "fractional core CPU", resourceName: corev1.ResourceCPU, quantity: "1500m", want: "1.5"},
		{name: "large Ki memory", resourceName: corev1.ResourceMemory, quantity: "17576384Ki", want: "16.76Gi"},
		{name: "fractional Gi memory", resourceName: corev1.ResourceMemory, quantity: "1536Mi", want: "1.5Gi"},
		{name: "Mi memory", resourceName: corev1.ResourceMemory, quantity: "768Mi", want: "768Mi"},
		{name: "Ki memory", resourceName: corev1.ResourceMemory, quantity: "8192Ki", want: "8Mi"},
		{name: "bytes below Ki", resourceName: corev1.ResourceMemory, quantity: "512", want: "512"},
		{name: "ephemeral storage", resourceName: corev1.ResourceEphemeralStorage, quantity: "134217728000", want: "125Gi"},
		{name: "huge pages", resourceName: "hugepages-2Mi", quantity: "131072Ki", want: "128Mi"},
		{name: "generic exact resource", resourceName: "example.com/gpu", quantity: "1500m", want: "1500m"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var quantity *resource.Quantity
			if test.quantity != "" {
				value := resource.MustParse(test.quantity)
				quantity = &value
			}
			if got := formatResourceQuantity(test.resourceName, quantity); got != test.want {
				t.Fatalf("formatResourceQuantity(%q, %q) = %q; want %q", test.resourceName, test.quantity, got, test.want)
			}
		})
	}
}

func TestAdaptiveDecimalBalancesDensityAndSmallValues(t *testing.T) {
	t.Parallel()
	tests := []struct {
		value float64
		want  string
	}{
		{value: 0, want: "0"},
		{value: 0.000123, want: "0.000123"},
		{value: -0.000123, want: "-0.000123"},
		{value: 0.01234, want: "0.0123"},
		{value: 0.1234, want: "0.12"},
		{value: 1.234, want: "1.23"},
		{value: 12.3456789, want: "12.3"},
	}
	for _, test := range tests {
		if got := adaptiveDecimal(test.value); got != test.want {
			t.Errorf("adaptiveDecimal(%g) = %q; want %q", test.value, got, test.want)
		}
	}
}
