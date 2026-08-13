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
		{name: "sub-core CPU", resourceName: corev1.ResourceCPU, quantity: "420m", want: "420m"},
		{name: "fractional millicore CPU", resourceName: corev1.ResourceCPU, quantity: "500u", want: "0.5m"},
		{name: "multi-core CPU", resourceName: corev1.ResourceCPU, quantity: "23256m", want: "23.256"},
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
