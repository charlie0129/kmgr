package store

import (
	"encoding/json"
	"math"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// The estimate deliberately favors eviction over under-counting. Raw JSON
// values are retained in interface/map/slice containers, and UIDStore keeps
// several secondary indexes, so encoded JSON length alone is not a useful
// memory ceiling. These constants approximate 64-bit Go container overhead
// and apply a two-times safety factor to the recursively retained object graph.
const (
	uidStoreBaseRetainedBytes   int64 = 2 << 10
	objectIndexRetainedBytes    int64 = 512
	topLevelIndexBytesPerObject int64 = 512
	topLevelIndexBytesPerOwner  int64 = 256
	nestedIndexBytesPerLink     int64 = 96
	maxRetainedBytes                  = math.MaxInt64
	maxRetainedEstimateDepth          = 256
)

func estimateRetainedObjectBytes(object *unstructured.Unstructured) int64 {
	if object == nil {
		return 0
	}
	raw := estimateRetainedValue(object.Object, 0)
	raw = saturatingRetainedMultiply(raw, 2)
	return saturatingRetainedAdd(objectIndexRetainedBytes, raw)
}

func estimateRetainedValue(value any, depth int) int64 {
	if depth > maxRetainedEstimateDepth {
		return maxRetainedBytes
	}

	switch typed := value.(type) {
	case nil:
		return 8
	case map[string]any:
		if typed == nil {
			return 8
		}
		// Map header plus deliberately padded bucket/key/value slots.
		total := saturatingRetainedAdd(64, saturatingRetainedMultiply(int64(len(typed)), 96))
		for key, child := range typed {
			total = saturatingRetainedAdd(total, saturatingRetainedAdd(16, int64(len(key))))
			total = saturatingRetainedAdd(total, estimateRetainedValue(child, depth+1))
		}
		return total
	case map[string]string:
		if typed == nil {
			return 8
		}
		total := saturatingRetainedAdd(64, saturatingRetainedMultiply(int64(len(typed)), 96))
		for key, child := range typed {
			total = saturatingRetainedAdd(total, saturatingRetainedAdd(16, int64(len(key))))
			total = saturatingRetainedAdd(total, saturatingRetainedAdd(16, int64(len(child))))
		}
		return total
	case []any:
		if typed == nil {
			return 24
		}
		total := saturatingRetainedAdd(24, saturatingRetainedMultiply(int64(cap(typed)), 16))
		for _, child := range typed {
			total = saturatingRetainedAdd(total, estimateRetainedValue(child, depth+1))
		}
		return total
	case []string:
		total := saturatingRetainedAdd(24, saturatingRetainedMultiply(int64(cap(typed)), 16))
		for _, child := range typed {
			total = saturatingRetainedAdd(total, saturatingRetainedAdd(16, int64(len(child))))
		}
		return total
	case []byte:
		return saturatingRetainedAdd(24, int64(cap(typed)))
	case string:
		return saturatingRetainedAdd(16, int64(len(typed)))
	case json.Number:
		return saturatingRetainedAdd(16, int64(len(typed)))
	case bool, int, int8, int16, int32, int64,
		uint, uint8, uint16, uint32, uint64, float32, float64:
		return 16
	default:
		// Kubernetes unstructured values are restricted to the cases above.
		// Treat an unexpected custom value as unbounded instead of allowing it to
		// bypass the warm memory ceiling with an unknowable retained graph.
		return maxRetainedBytes
	}
}

func saturatingRetainedAdd(left, right int64) int64 {
	if left < 0 || right < 0 || left > maxRetainedBytes-right {
		return maxRetainedBytes
	}
	return left + right
}

func saturatingRetainedMultiply(value, factor int64) int64 {
	if value < 0 || factor < 0 || (factor != 0 && value > maxRetainedBytes/factor) {
		return maxRetainedBytes
	}
	return value * factor
}
