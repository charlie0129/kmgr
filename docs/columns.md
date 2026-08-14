# Programmable columns

Column definitions are stored at `~/Library/Application Support/kmgr/columns.yaml`. The file schema starts at `kmgr.charlie0129.dev/v1alpha1`; the independently versioned CEL environment is `kmgr.cel/v1`. A definition must declare its result type. Changing expression semantics requires a new environment version and an explicit migration error rather than silent reinterpretation.

## File schema and complete example

The file is one strict YAML mapping. Unknown fields, duplicate exact view
matches, duplicate column IDs within a view, unsupported version strings, and
invalid source/type combinations reject the new configuration as a whole. An
invalid external edit does not partially replace the last valid compiled
configuration. The native editor accepts ordinary JSON-compatible YAML and
writes formatted JSON, which is itself valid YAML; it deliberately refuses to
rewrite anchors, aliases, merge keys, custom tags, and non-string mapping keys.

This example exercises every supported top-level and per-column field:

```yaml
apiVersion: kmgr.charlie0129.dev/v1alpha1
celEnvironment: kmgr.cel/v1

accelerators:
  # Omit this field to use /gpu, /ppu, and /dcu. An explicit [] disables
  # suffix-based accelerator discovery.
  autoDetectSuffixes:
    - /gpu
    - /ppu
    - /dcu
  resources:
    # Exact keys listed here remain distinct and are offered even when absent
    # from the currently retained Pod/Node objects.
    aliyun.com/ppu:
      displayName: PPU
    example.com/fpga-card:
      displayName: FPGA

views:
  - match:
      group: ""       # the core API group
      version: v1
      resource: pods  # plural REST resource name, not Kind
    columns:
      - id: namespace
        title: Namespace
        source: builtin
        value: namespace
        type: string
        alignment: leading
        width: 140
        enabled: true

      - id: name
        title: Name
        source: builtin
        value: name
        type: string
        width: 280

      - id: cpu
        title: CPU use / request / limit
        source: metric
        value: cpu
        type: resourceUsage
        alignment: trailing
        width: 230

      - id: finalizers
        title: Finalizers
        source: cel
        expression: object.?metadata.?finalizers.orValue([])
        type: string
        alignment: leading
        missing: "—"
        width: 220
        listJoiner: " · "
        enabled: true

      - id: ppu
        title: PPU request / limit
        source: metric
        value: resource:aliyun.com/ppu
        type: resourceUsage
        alignment: trailing
        width: 210
        enabled: false
```

The top-level fields are:

| Field | Required | Contract |
| --- | --- | --- |
| `apiVersion` | yes | Must be exactly `kmgr.charlie0129.dev/v1alpha1`. |
| `celEnvironment` | yes | Must be exactly `kmgr.cel/v1`. It versions CEL syntax, activation, helpers, and coercion independently from the file shape. |
| `views` | no | Ordered exact-GVR layouts. An omitted or unmatched GVR uses Kmgr's built-in layout. |
| `accelerators` | no | Exact-resource and suffix rules for optional accelerator discovery; omission uses the default suffixes. |

Each `views[].match` compares the exact `group`, `version`, and `resource`.
There are no wildcards or Kind-name matches. `group` may be omitted for the
core API group; `version` and the plural REST `resource` are required. At most
one view may match a given triple. The order of `columns` is its normal table
order.

Each column supports:

| Field | Required | Contract |
| --- | --- | --- |
| `id` | yes | Stable, case-sensitive table/protocol identity; non-empty and unique within this view. It need not equal a native extractor's `value`. |
| `title` | yes | Non-empty native table heading. |
| `source` | yes | Exactly `cel`, `builtin`, or `metric`. |
| `expression` | for `cel` | CEL source. It is forbidden for `builtin` and `metric`. |
| `value` | for `builtin`/`metric` | Validated native extractor. It is forbidden for `cel`. |
| `type` | yes | Declared typed value. CEL supports `string`, `integer`, `number`, `boolean`, `quantity`, `timestamp`, or `duration`; native metric extractors require `resourceUsage`; built-ins require their documented native type. |
| `alignment` | no | `leading`, `center`, or `trailing`; omission uses leading alignment. |
| `missing` | no | CEL-only missing/null/empty-optional text; omission or an empty value uses `—`. |
| `width` | no | Initial width in points; omit for the extractor/default width. If present, it must be finite and non-negative. Per-window width restoration may override it. |
| `listJoiner` | no | CEL-only separator when a `string` column directly returns a scalar list; omission or an empty value uses `, `. |
| `enabled` | no | Whether the definition is normally visible. Omission means `true`; a disabled definition remains available to the Columns window. |

`accelerators.autoDetectSuffixes` performs an exact, case-sensitive suffix
test on Kubernetes resource names. Omitting it uses `[/gpu, /ppu, /dcu]`; an
explicit empty list disables suffix detection. Each key in
`accelerators.resources` is an independently tracked exact extended-resource
name. Its optional `displayName` changes only the label, never the resource
identity. Listing a resource here makes it available to optional-resource
discovery even when it is not currently present. It does not create a persisted
table definition by itself: add a `metric` column with
`value: resource:<exact-name>` when a specific persisted layout is desired.

## `kmgr.cel/v1` activation

- `object`: dynamic Kubernetes object. For Secrets, the engine constructs a sanitized copy with top-level `data` and `stringData` removed before CEL receives it.
- `metrics`: dynamic, non-sensitive computed metrics/accounting values. Exact huge-page and accelerator resource names remain separate map keys.
- `context`: the stable non-sensitive GVR and namespace-scope map enumerated
  below.
- `now`: one CEL timestamp captured once for an entire projection batch.

The `context` map has exactly these stable keys in `kmgr.cel/v1`:

| Key | CEL type | Meaning |
| --- | --- | --- |
| `clusterSessionID` | `string` | Opaque identity of the current engine cluster session. |
| `group` | `string` | Kubernetes API group; empty for the core group. |
| `version` | `string` | Kubernetes API version. |
| `resource` | `string` | Plural REST resource name. |
| `kind` | `string` | Discovered Kubernetes Kind. |
| `namespaced` | `bool` | Whether the resource itself is namespace-scoped. |
| `allNamespaces` | `bool` | Whether this view requests all namespaces. |
| `namespaces` | `list<string>` | The explicitly selected namespaces; empty when none are explicitly selected. |

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

`kmgr.cel/v1` also exposes two namespaced, pure helpers for common bounded
column operations:

```cel
kmgr.sum([1, 2, 3])                         // 6
kmgr.join(["ready", 3, true], " / ")       // "ready / 3 / true"
```

`kmgr.sum(list)` accepts one homogeneous list of `int`, `uint`, or `double`
and returns the same numeric kind (an empty list returns integer zero).
`kmgr.join(list, separator)` accepts string, integer, unsigned integer,
double, and boolean elements and can be composed inside a larger expression.
Both helpers reject more than 128 elements; `kmgr.join` also stops before its
UTF-8 result exceeds 4 KiB. Their runtime cost grows with list traversal and,
for join, produced bytes, so the per-evaluation cost limit applies to helper
work as well as baseline CEL operations. The existing behavior where a string
column directly returns a scalar list and uses that column's `listJoiner`
remains supported independently.

The supported CEL-declared types are `string`, `integer`, `number`, `boolean`, `quantity`, `timestamp`, and `duration`. Quantity expressions return one Kubernetes quantity string; the helper validates and retains its exact canonical quantity alongside display text and an approximate numeric UI hint. Authoritative sorting uses Kubernetes quantity semantics, not lexical display order or the approximate hint. Integer results remain signed 64-bit values across IPC and are not converted through a double. A string column may accept a list of scalar values, joined by its configured separator. `resourceUsage` is reserved for native metric/accounting extractors and is not a valid CEL result type.

Evaluation is deterministic and side-effect free. Each evaluation has a runtime cost limit (10,000 by default), a maximum of 128 list elements, and a 4 KiB rendered-value limit. Programs are compiled and type-checked when their definition/environment changes, then reused. Absent, null, and empty optional results render as `—` unless the definition supplies another missing value. Runtime failures belong to the individual column/cell and do not discard a row or view.

Sorting uses the typed result retained alongside display text. It never reparses formatted display text.

## Columns window

The native built-in/metric picker is filtered to the current resource GVR and
marks extractors already represented by the draft. It can add a catalog entry
disabled for deliberate review, or validate and add an exact Kubernetes
resource name such as `nvidia.com/gpu`. The CEL editor compiles each current
revision through the engine and previews it against the selected table object
when exactly one is selected, otherwise against a bounded sample object. Only
the latest successful validation can be committed.

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

### Automatic optional-resource columns

Once the base Pod or Node snapshot has produced rows, or has completed empty,
Kmgr performs a cache-only catalog query for optional scheduler resources. It
uses exact resource names: equal friendly labels never merge vendor resources.
Present huge-page and accelerator entries become enabled transient columns;
configured-but-absent entries remain disabled. Ephemeral storage remains in
the existing built-in column instead of creating a duplicate exact-resource
column.

Pod and Node stream messages carry only a bounded advisory set of exact
scheduler resource names observed behind their compact rows. A new name, or an
overflow marker, triggers another authenticated cache-only catalog query. The
hint never installs a column directly, and stream delivery never waits for the
catalog or Kubernetes API I/O; it closes the cold-empty race where the initial
catalog query can finish just before the first huge-page or accelerator object
arrives.

The catalog is optional enrichment. Failure is silent and does not change the
base view's rows, freshness, or error state. A transient overlay lasts only for
the current helper session and exact GVR, survives a same-GVR stream reopen,
and is never saved to `columns.yaml`. Persisted definitions always win by both
display ID and exact extractor identity, including when the persisted column is
disabled.

CPU and memory columns subscribe lazily to `metrics.k8s.io/v1beta1`. A view
without a metric column (and without a CEL expression that reads `metrics`)
does not start a metrics fetch. Metrics failure leaves the base rows and
request/limit or allocatable accounting intact.
