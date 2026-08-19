package view

import (
	"context"
	"testing"
	"time"

	"github.com/charlie0129/kmgr/backend/internal/metrics"
	kmgrv1 "github.com/charlie0129/kmgr/gen/go/kmgr/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	viewcolumns "github.com/charlie0129/kmgr/backend/internal/view/columns"
)

func TestProjectorFromProtoInstallsResolvedNativeExtractorAliases(t *testing.T) {
	t.Parallel()
	resolver := staticColumnResolver{resolution: viewcolumns.Resolution{
		Extractors: map[string]viewcolumns.Extractor{
			"gpu": {Source: "metric", Value: metricColumnID("nvidia.com/gpu")},
		},
	}}
	projector, err := projectorFromProto("session-a", &kmgrv1.ViewSpec{
		Resource:  &kmgrv1.ResourceType{Version: "v1", Resource: "pods", Kind: "Pod", Namespaced: true},
		ColumnIds: []string{"gpu"},
	}, resolver, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := projector.extractorID("gpu"); got != "resource:nvidia.com/gpu" {
		t.Fatalf("resolved extractor = %q", got)
	}
}

func TestRuntimeConfiguredAliasesDriveMetricProviderLazily(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name      string
		extractor string
		wantOpens int64
	}{
		{name: "actual CPU", extractor: PodCPUColumn, wantOpens: 1},
		{name: "exact allocation", extractor: metricColumnID("nvidia.com/gpu"), wantOpens: 0},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			client := newScriptedResource()
			client.listPages = []*unstructured.UnstructuredList{listPage(
				"rv-1", "", pod("uid-a", "ns", "api", "Running", 0, nil, time.Time{}),
			)}
			provider, err := metrics.NewProvider(metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
				return map[string]metrics.Sample{}, nil
			}), time.Hour)
			if err != nil {
				t.Fatal(err)
			}
			metricSource := &fakeMetricSource{provider: provider}
			resolver := staticColumnResolver{resolution: viewcolumns.Resolution{
				Extractors: map[string]viewcolumns.Extractor{
					"custom": {Source: "metric", Value: test.extractor},
				},
			}}
			runtime, err := NewRuntime(RuntimeConfig{
				Source:  &fakeResourceSource{authority: "cluster-a", client: client},
				Metrics: metricSource, Columns: resolver, BatchDelay: time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			defer runtime.Close()
			request := openView("session", "view", 1)
			request.Spec.ColumnIds = []string{"custom"}
			subscription, err := runtime.Open(request)
			if err != nil {
				t.Fatal(err)
			}
			defer subscription.Close()
			waitForSnapshotUID(t, subscription, "uid-a")
			if got := metricSource.opens.Load(); got != test.wantOpens {
				t.Fatalf("metric provider opens = %d, want %d", got, test.wantOpens)
			}
		})
	}
}

func TestRuntimeMetricPlanPassesLabelsAndNeverBroadensFieldSelectedPods(t *testing.T) {
	t.Parallel()
	provider, err := metrics.NewProvider(
		metricFetcherFunc(func(context.Context) (map[string]metrics.Sample, error) {
			return map[string]metrics.Sample{}, nil
		}),
		time.Hour,
	)
	if err != nil {
		t.Fatal(err)
	}
	metricSource := &fakeMetricSource{provider: provider}
	runtime, err := NewRuntime(RuntimeConfig{
		Source: &fakeResourceSource{
			authority: "cluster-a", client: newScriptedResource(),
		},
		Metrics: metricSource, BatchDelay: time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()

	sharedRequest := openView("session", "label-selected", 1)
	sharedRequest.Spec.ColumnIds = []string{"name", PodCPUColumn}
	sharedRequest.Spec.LabelSelector = "tier=frontend,app==api"
	shared, err := runtime.Open(sharedRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer shared.Close()
	requests := metricSource.metricRequests()
	if len(requests) != 1 || requests[0].kind != metrics.PodMetrics ||
		requests[0].namespace != "ns" ||
		requests[0].labelSelector != "app=api,tier=frontend" {
		t.Fatalf("shared metric requests = %#v", requests)
	}
	if shared.metricPlan.strategy != metricFetchSharedList {
		t.Fatalf("label-selected metric plan = %#v", shared.metricPlan)
	}

	fieldRequest := openView("session", "field-selected", 1)
	fieldRequest.Spec.ColumnIds = []string{"name", PodCPUColumn}
	fieldRequest.Spec.FilterExpression = "field:spec.nodeName==node-a"
	fieldSelected, err := runtime.Open(fieldRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer fieldSelected.Close()
	if got := metricSource.opens.Load(); got != 1 {
		t.Fatalf("metrics LIST providers opened = %d, want only label-selected view", got)
	}
	if got := metricSource.metricRequests(); len(got) != 1 {
		t.Fatalf("field-selected Pod opened broad metrics provider: %#v", got)
	}
	if fieldSelected.metricPlan.strategy != metricFetchPodObjects ||
		!fieldSelected.metricPlan.dependency.display {
		t.Fatalf("field-selected metric plan = %#v", fieldSelected.metricPlan)
	}
}

type staticColumnResolver struct {
	resolution viewcolumns.Resolution
}

func (r staticColumnResolver) Resolve(
	_, _, _ string,
	_ []string,
	_ string,
) (viewcolumns.Resolution, string, error) {
	return r.resolution, "test", nil
}
