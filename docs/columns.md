# Programmable columns

Column definitions are stored at `~/Library/Application Support/kmgr/columns.yaml`. The file schema starts at `kmgr.charlie0129.dev/v1alpha1`; the independently versioned CEL environment is `kmgr.cel/v1`. A definition must declare its result type. Changing expression semantics requires a new environment version and an explicit migration error rather than silent reinterpretation.

## `kmgr.cel/v1` activation

- `object`: dynamic Kubernetes object. For Secrets, the engine constructs a sanitized copy with top-level `data` and `stringData` removed before CEL receives it.
- `metrics`: dynamic, non-sensitive computed metrics/accounting values. Exact huge-page and accelerator resource names remain separate map keys.
- `context`: dynamic non-sensitive GVR, namespace-scope, and view metadata.
- `now`: one CEL timestamp captured once for an entire projection batch.

For Pod and Node views, `metrics` has this stable dynamic shape:

| Key | Type | Meaning |
| --- | --- | --- |
| `available` | `bool` | Actual provider-backed usage is available for this refresh. |
| `stale` | `bool` | Provider-backed usage is retained from a failed refresh. |
| `provider` | `string` | Actual-usage provider identity (`metrics.k8s.io/v1beta1`). |
| `resources` | `map<string, number>` | Actual usage keyed by exact resource name; CPU is nanocores, byte resources are bytes, and generic resources are counts. |
| `measuredAt` | `timestamp`, optional | Provider sample timestamp. |
| `accountingAvailable` | `bool` | Scheduler accounting could be calculated for this object/revision. |
| `requests` | `map<string, number>` | Effective Pod requests or aggregate Node requests, keyed by exact resource name. |
| `limits` | `map<string, number>` | Effective Pod limits or aggregate Node limits, keyed by exact resource name. |
| `allocatable` | `map<string, number>` | Node allocatable resources; present on Node views. |
| `capacity` | `map<string, number>` | Node physical capacity; present on Node views. |
| `podCount` | `integer` | Relevant bound Pod count; present when Node accounting is ready. |

Scheduler-map CPU values are cores, memory/storage/huge-page values are bytes,
and extended resources are counts. Pod requests and limits use Kubernetes'
effective scheduling formula, including regular containers, restartable init
containers, non-restartable init containers, Pod-level resources, and Pod
overhead. Exact keys such as `hugepages-2Mi`, `hugepages-1Gi`,
`nvidia.com/gpu`, and `aliyun.com/ppu` are independent map entries and are
never summed together.

CEL optional syntax is enabled. For example:

```cel
object.?spec.?nodeName.orValue("—")
object.?metadata.?labels[?"team"].orValue("—")
```

The supported declared types are `string`, `integer`, `number`, `boolean`, `quantity`, `timestamp`, and `duration`. Quantity values currently use their exact Kubernetes quantity string; typed native quantity and resource-usage results are provided by built-in metric columns. A string column may accept a list of scalar values, joined by its configured separator.

Evaluation is deterministic and side-effect free. Each evaluation has a runtime cost limit (10,000 by default), a maximum of 128 list elements, and a 4 KiB rendered-value limit. Programs are compiled and type-checked when their definition/environment changes, then reused. Absent, null, and empty optional results render as `—` unless the definition supplies another missing value. Runtime failures belong to the individual column/cell and do not discard a row or view.

Sorting uses the typed result retained alongside display text. It never reparses formatted display text.

## Built-in resource usage columns

For native columns, `id` is the stable table/UI identity and `value` selects
the backend extractor. They do not need to match. For example, the following
keeps the table column ID `gpu` while accounting the exact Kubernetes resource
`nvidia.com/gpu`:

```yaml
- id: gpu
  title: GPU
  source: metric
  value: resource:nvidia.com/gpu
  type: resourceUsage
```

Built-in values include `name`, `namespace`, `kind`, `status`, `node`,
`ready`, `restarts`, `age`, `created`, and `resourceVersion`; the documented
Pod-qualified forms such as `pod.status` resolve to the same optimized
extractors. Metric values include `cpu`, `memory`, `ephemeral-storage`, Node
request/limit and Pod-count variants, and `resource:<exact-resource-name>`.
The documented qualified forms such as `pod.cpu.usageRequestLimit` are also accepted.
Native result types are part of that contract: `ready` is `string`, `restarts`
is `integer`, `age` is `duration`, `created` is `timestamp`, and metric values
are `resourceUsage`; other metadata/status built-ins are `string`.
Source, value, result type, and resource-kind compatibility are validated when
the configuration is compiled. CEL columns cannot declare `value`, and native
columns cannot declare a CEL expression.

Pod and Node views use the built-in IDs `cpu`, `memory`, and
`ephemeral-storage`. Pods render actual usage / effective request / effective
limit; Nodes render actual usage / allocatable, with physical capacity in the
tooltip. These cells remain typed `resourceUsage` values even when actual usage
is unavailable, so scheduler accounting is not confused with measured usage.
CPU display values use millicores below one core and compact decimal cores at
or above one core. Memory, ephemeral storage, and each exact huge-page resource
use the largest readable binary unit (`Ki`, `Mi`, `Gi`, and so on), with up to
two fractional digits. Tooltips retain the exact canonical Kubernetes
Quantity, and sorting continues to use the unformatted typed numeric value.
Generic extended resources retain their canonical Quantity text because their
units are resource-specific counts rather than bytes.

An explicitly configured exact resource uses the value
`resource:<kubernetes-resource-name>`, for example
`resource:hugepages-2Mi`, `resource:nvidia.com/gpu`, or
`resource:aliyun.com/ppu`. Its display ID may be a shorter stable name such as
`gpu`. Declare it as a `metric` source with type `resourceUsage`. Exact names
are never merged. Metrics Server usually
does not report huge-page or accelerator utilization, so these Pod cells show
effective request / limit with actual usage unavailable; they never label
allocation as utilization.

CPU and memory columns subscribe lazily to `metrics.k8s.io/v1beta1`. A view
without a metric column (and without a CEL expression that reads `metrics`)
does not start a metrics fetch. Metrics failure leaves the base rows and
request/limit or allocatable accounting intact.
