package store

import (
	"fmt"
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

const syntheticStoreRows = 100_000

var benchmarkUIDStore *UIDStore

// BenchmarkUIDStoreUpsert100K measures the LIST hot path that admits immutable
// unstructured objects into UID and secondary indexes. Keep object construction
// outside the timed section so retained-byte accounting regressions remain
// visible independently from fixture allocation.
func BenchmarkUIDStoreUpsert100K(b *testing.B) {
	objects := make([]*unstructured.Unstructured, syntheticStoreRows)
	for index := range objects {
		objects[index] = &unstructured.Unstructured{Object: map[string]any{
			"apiVersion": "v1",
			"kind":       "Pod",
			"metadata": map[string]any{
				"uid":       fmt.Sprintf("uid-%d", index),
				"namespace": fmt.Sprintf("namespace-%d", index%100),
				"name":      fmt.Sprintf("pod-%d", index),
			},
			"spec": map[string]any{
				"nodeName": fmt.Sprintf("node-%d", index%1_000),
			},
		}}
	}

	b.ReportAllocs()
	b.ResetTimer()
	for range b.N {
		store := New()
		for _, object := range objects {
			store.Upsert(object)
		}
		benchmarkUIDStore = store
	}
	b.StopTimer()
	b.ReportMetric(syntheticStoreRows, "objects/op")
	b.ReportMetric(float64(benchmarkUIDStore.RetainedBytes()), "retained_bytes/op")
	if benchmarkUIDStore.Len() != syntheticStoreRows {
		b.Fatalf("stored objects = %d, want %d", benchmarkUIDStore.Len(), syntheticStoreRows)
	}
}
