package columns

import (
	"testing"
	"time"
)

// Keep these expressions identical to the kmgr.cel/v1 examples displayed by
// CELColumnEditorWindowController. The help must never advertise syntax or
// helper semantics that the engine cannot compile and evaluate.
func TestCELColumnHelpExamplesCompileAndEvaluate(t *testing.T) {
	t.Parallel()
	compiler, err := NewCompiler(DefaultCostLimit)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)
	pod := helpExamplePod()
	node := helpExampleNode()
	workload := helpExampleWorkload()
	tests := []struct {
		name       string
		expression string
		resultType ResultType
		activation Activation
		want       string
	}{
		{
			name: "safe label", expression: `object.?metadata.?labels[?"app"].orValue("—")`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "api",
		},
		{
			name: "safe phase", expression: `object.?status.?phase.orValue("Unknown")`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "Running",
		},
		{
			name: "safe replicas", expression: `object.?spec.?replicas.orValue(0)`,
			resultType: ResultInteger, activation: Activation{Object: workload}, want: "3",
		},
		{
			name: "condition count", expression: `object.?status.?conditions.orValue([]).size()`,
			resultType: ResultInteger, activation: Activation{Object: pod}, want: "2",
		},
		{
			name: "pod node", expression: `object.?spec.?nodeName.orValue("Unscheduled")`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "worker-1",
		},
		{
			name: "pod tolerations",
			expression: `object.?spec.?tolerations.orValue([]).map(t,
  t.?key.orValue("*") + ":" + t.?operator.orValue("Equal") + ":" + t.?effect.orValue("*"))`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "dedicated:Equal:NoSchedule",
		},
		{
			name: "containers defining env",
			expression: `object.?spec.?containers.orValue([])
  .filter(c, c.?env.orValue([]).exists(e, e.name == "DEBUG"))
  .map(c, c.name)`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "api",
		},
		{
			name: "env values",
			expression: `object.?spec.?containers.orValue([])
  .filter(c, c.?env.orValue([]).exists(e, e.name == "JAVA_OPTS"))
  .map(c, c.name + "=" + kmgr.join(c.?env.orValue([])
    .filter(e, e.name == "JAVA_OPTS")
    .map(e, e.?value.orValue(e.?valueFrom.hasValue() ? "<valueFrom>" : "<unset>")), "|"))`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "api=-Xmx1g",
		},
		{
			name: "owners",
			expression: `object.?metadata.?ownerReferences.orValue([])
  .map(o, o.kind + "/" + o.name)`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "ReplicaSet/api-abc",
		},
		{
			name: "restart total",
			expression: `kmgr.sum(object.?status.?containerStatuses.orValue([])
  .map(c, c.?restartCount.orValue(0)))`,
			resultType: ResultInteger, activation: Activation{Object: pod}, want: "3",
		},
		{
			name: "ready container count",
			expression: `object.?status.?containerStatuses.orValue([])
  .filter(c, c.?ready.orValue(false)).size()`,
			resultType: ResultInteger, activation: Activation{Object: pod}, want: "1",
		},
		{
			name: "container CPU requests",
			expression: `object.?spec.?containers.orValue([])
  .map(c, c.name + "=" + c.?resources.?requests[?"cpu"].orValue("0"))`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "api=250m, sidecar=0",
		},
		{
			name: "PVC claims",
			expression: `object.?spec.?volumes.orValue([])
  .filter(v, v.?persistentVolumeClaim.hasValue())
  .map(v, v.persistentVolumeClaim.claimName)`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "data",
		},
		{
			name: "container images", expression: `object.?spec.?containers.orValue([]).map(c, c.image)`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "repo/api:v1, repo/side:v1",
		},
		{
			name: "node taints",
			expression: `object.?spec.?taints.orValue([]).map(t,
  t.key + "=" + t.?value.orValue("") + ":" + t.effect)`,
			resultType: ResultString, activation: Activation{Object: node}, want: "dedicated=gpu:NoSchedule",
		},
		{
			name: "node GPU", expression: `object.?status.?allocatable[?"nvidia.com/gpu"].orValue("0")`,
			resultType: ResultQuantity, activation: Activation{Object: node}, want: "8",
		},
		{
			name: "node internal IP",
			expression: `object.?status.?addresses.orValue([])
  .filter(a, a.type == "InternalIP").map(a, a.address)`,
			resultType: ResultString, activation: Activation{Object: node}, want: "10.0.0.1",
		},
		{
			name: "true node conditions",
			expression: `object.?status.?conditions.orValue([])
  .filter(c, c.status == "True").map(c, c.type)`,
			resultType: ResultString, activation: Activation{Object: node}, want: "Ready",
		},
		{
			name: "node unschedulable", expression: `object.?spec.?unschedulable.orValue(false)`,
			resultType: ResultBoolean, activation: Activation{Object: node}, want: "false",
		},
		{
			name:       "unavailable replicas",
			expression: `object.?spec.?replicas.orValue(0) - object.?status.?availableReplicas.orValue(0)`,
			resultType: ResultInteger, activation: Activation{Object: workload}, want: "1",
		},
		{
			name: "observed generation",
			expression: `object.?metadata.?generation.orValue(0) ==
  object.?status.?observedGeneration.orValue(-1)`,
			resultType: ResultBoolean, activation: Activation{Object: workload}, want: "true",
		},
		{
			name:       "finalizers",
			expression: `kmgr.join(object.?metadata.?finalizers.orValue([]), " · ")`,
			resultType: ResultString, activation: Activation{Object: pod}, want: "cleanup.example",
		},
		{
			name: "age", expression: `object.?metadata.?creationTimestamp.hasValue()
  ? now - timestamp(object.metadata.creationTimestamp)
  : duration("0s")`,
			resultType: ResultDuration, activation: Activation{Object: pod, Now: now}, want: "1h0m0s",
		},
		{
			name: "terminating", expression: `object.?metadata.?deletionTimestamp.hasValue()`,
			resultType: ResultBoolean, activation: Activation{Object: pod}, want: "false",
		},
		{
			name: "context kind", expression: `context.?kind.orValue("Unknown")`,
			resultType: ResultString, activation: Activation{Context: map[string]any{"kind": "Pod"}}, want: "Pod",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			program, err := compiler.Compile(Definition{
				ID: "help", Expression: test.expression, ResultType: test.resultType,
			})
			if err != nil {
				t.Fatalf("Compile(%s): %v", test.expression, err)
			}
			value, err := program.Evaluate(test.activation)
			if err != nil {
				t.Fatalf("Evaluate(%s): %v", test.expression, err)
			}
			if value.Display != test.want {
				t.Fatalf("Evaluate(%s) = %q, want %q", test.expression, value.Display, test.want)
			}
		})
	}
}

func helpExamplePod() map[string]any {
	return map[string]any{
		"metadata": map[string]any{
			"labels":            map[string]any{"app": "api"},
			"ownerReferences":   []any{map[string]any{"kind": "ReplicaSet", "name": "api-abc"}},
			"finalizers":        []any{"cleanup.example"},
			"creationTimestamp": "2026-08-20T11:00:00Z",
		},
		"spec": map[string]any{
			"nodeName": "worker-1",
			"tolerations": []any{map[string]any{
				"key": "dedicated", "operator": "Equal", "effect": "NoSchedule",
			}},
			"containers": []any{
				map[string]any{
					"name": "api", "image": "repo/api:v1",
					"env": []any{
						map[string]any{"name": "DEBUG", "value": "true"},
						map[string]any{"name": "JAVA_OPTS", "value": "-Xmx1g"},
					},
					"resources": map[string]any{"requests": map[string]any{"cpu": "250m"}},
				},
				map[string]any{"name": "sidecar", "image": "repo/side:v1"},
			},
			"volumes": []any{
				map[string]any{"name": "data-volume", "persistentVolumeClaim": map[string]any{"claimName": "data"}},
				map[string]any{"name": "scratch", "emptyDir": map[string]any{}},
			},
		},
		"status": map[string]any{
			"phase": "Running",
			"conditions": []any{
				map[string]any{"type": "Ready", "status": "True"},
				map[string]any{"type": "PodScheduled", "status": "True"},
			},
			"containerStatuses": []any{
				map[string]any{"name": "api", "ready": true, "restartCount": int64(3)},
				map[string]any{"name": "sidecar", "ready": false, "restartCount": int64(0)},
			},
		},
	}
}

func helpExampleNode() map[string]any {
	return map[string]any{
		"spec": map[string]any{
			"unschedulable": false,
			"taints": []any{map[string]any{
				"key": "dedicated", "value": "gpu", "effect": "NoSchedule",
			}},
		},
		"status": map[string]any{
			"allocatable": map[string]any{"nvidia.com/gpu": "8"},
			"addresses": []any{
				map[string]any{"type": "InternalIP", "address": "10.0.0.1"},
				map[string]any{"type": "Hostname", "address": "worker-1"},
			},
			"conditions": []any{
				map[string]any{"type": "Ready", "status": "True"},
				map[string]any{"type": "MemoryPressure", "status": "False"},
			},
		},
	}
}

func helpExampleWorkload() map[string]any {
	return map[string]any{
		"metadata": map[string]any{"generation": int64(7)},
		"spec":     map[string]any{"replicas": int64(3)},
		"status": map[string]any{
			"availableReplicas": int64(2), "observedGeneration": int64(7),
		},
	}
}
