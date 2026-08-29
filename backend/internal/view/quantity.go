package view

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"

	"github.com/charlie0129/kmgr/backend/internal/kubequantity"
)

// formatResourceQuantity keeps Kubernetes resource semantics while choosing a
// compact, consistent presentation unit. The exact canonical Quantity string
// remains available in cell tooltips; this function is only for display text.
func formatResourceQuantity(name corev1.ResourceName, quantity *resource.Quantity) string {
	if quantity == nil {
		return DefaultMissingCell
	}
	return kubequantity.Format(name, quantity)
}
