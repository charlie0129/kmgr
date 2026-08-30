# Programmable columns

Column definitions are stored at `~/Library/Application Support/kmgr/columns.yaml`. The current file metadata is `kmgr.chlc.cc/v1alpha1`; the independently versioned CEL environment is `kmgr.cel/v1`. A definition must declare its result type. Changing expression semantics requires a new environment version and an explicit migration error rather than silent reinterpretation.

## File schema and complete example

The file is one strict YAML mapping. Kmgr checks field names, field types, enum
values, and source-specific/native values before it considers the metadata.
`apiVersion` is metadata rather than a compatibility allow-list: any non-empty
value whose other fields are compatible can be migrated to the current value.
Omitted fields that have safe defaults are filled during that migration.
Unknown or removed fields, duplicate exact view matches, duplicate column IDs
within a view, an incompatible CEL environment, and invalid source/type or
native-extractor combinations reject the document as a whole. An invalid
existing file is copied to a restrictive
`columns.yaml.invalid-<UUID>.bak`, replaced atomically with the default
document, and surfaced as a warning. A compatible migration is rewritten and
shown as a notice. The native editor accepts ordinary JSON-compatible YAML and
writes formatted JSON, which is itself valid YAML; it deliberately refuses to
rewrite anchors, aliases, merge keys, custom tags, and non-string mapping keys.

This example exercises every supported top-level and per-column field:

```yaml
apiVersion: kmgr.chlc.cc/v1alpha1
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
| `apiVersion` | yes | Must be a non-empty string. Compatible values are metadata and are rewritten to `kmgr.chlc.cc/v1alpha1`; the value is not an allow-list. |
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
| `source` | yes | Exactly `cel`, `builtin`, `metric`, or `server`. `server` identifies a column supplied by a Kubernetes `metav1.Table` response. |
| `expression` | for `cel` | CEL source. It is forbidden for `builtin`, `metric`, and `server`. |
| `value` | for `builtin`/`metric` | Validated native extractor. It is forbidden for `cel` and `server`. |
| `type` | yes | Declared typed value. CEL and server columns support `string`, `integer`, `number`, `boolean`, `quantity`, `timestamp`, or `duration`; native metric extractors require `resourceUsage`; built-ins require their catalog type. |
| `alignment` | no | `leading`, `center`, or `trailing`; omission uses leading alignment. |
| `missing` | no | CEL-only missing/null/empty-optional text; omission or an empty value uses `—`. |
| `width` | no | Initial width in points; omit for the extractor/default width. If present, it must be finite and non-negative. Per-window width restoration may override it. |
| `listJoiner` | no | CEL-only separator when a `string` column directly returns a scalar list; omission or an empty value uses `, `. |
| `enabled` | no | Whether the definition is normally visible. Omission means `true`; a disabled definition remains available to the Columns window. |

`server` definitions are normally discovered rather than handwritten. Kmgr
persists them when the user changes a server column's visibility, order, or
width. Their stable `id` must continue to match the ID announced by the current
Table schema; they have neither `value` nor `expression` and cannot use the
`resourceUsage` result type.

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
| `accountingAvailable` | `bool` | The current Pod or Node object could be decoded for object-local resource accounting. |
| `requests` | `map<string, number>` | Effective Pod requests keyed by exact resource name. This map is empty for Nodes. |
| `limits` | `map<string, number>` | Effective Pod limits keyed by exact resource name. This map is empty for Nodes. |
| `allocatable` | `map<string, number>` | Node allocatable resources; present on Node views. |
| `capacity` | `map<string, number>` | Node physical capacity; present on Node views. |

Object-local scheduler-map CPU values are cores,
memory/storage/huge-page values are bytes, and extended resources are counts.
Pod requests and limits use Kubernetes'
effective scheduling formula, including regular containers, restartable init
containers, non-restartable init containers, Pod-level resources, and Pod
overhead. Exact keys such as `hugepages-2Mi`, `hugepages-1Gi`,
`nvidia.com/gpu`, and `aliyun.com/ppu` are independent map entries and are
never summed together.

Node activation deliberately does not aggregate Pods. It exposes only the
Node object's `status.allocatable` and `status.capacity` plus optional actual
usage from Metrics API. Consequently, opening a Node view never starts a Pod
LIST/WATCH.

CEL optional syntax is enabled. For example:

```cel
object.?spec.?nodeName.orValue("—")
object.?metadata.?labels[?"team"].orValue("—")
```

`kmgr.cel/v1` enables exactly three CEL library layers:

1. the standard CEL operators, functions, and macros supplied by the pinned
   `cel-go` v0.31.0 environment, including `has`, `all`, `exists`,
   `exists_one`, `map` (with its filtering form), and `filter`;
2. `cel-go` optional types, including optional field/map/list selection,
   optional literal elements, `optional.of`, `optional.ofNonZeroValue`,
   `optional.none`, `hasValue`, `value`, `or`, `orValue`, `optMap`,
   `optFlatMap`, `first`, `last`, `optional.unwrap`, and `unwrapOpt`;
3. the two Kmgr helpers documented below.

No `cel-go/ext` string, math, regex, encoding, set, or Kubernetes-specific
extension library is enabled. Adding one would change the CEL environment and
therefore requires a new `celEnvironment` version rather than silently making
new expressions valid under `kmgr.cel/v1`.

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

The supported CEL-declared types are `string`, `integer`, `number`, `boolean`,
`quantity`, `timestamp`, and `duration`. Coercion is intentionally narrow:

| Declared type | Accepted CEL result | Display/typed behavior |
| --- | --- | --- |
| `string` | `string`, or a list containing only `string`, `int`, `uint`, `double`, and `bool` scalars | A scalar is retained exactly. A list is formatted element by element and joined with `listJoiner`; no map/object/list nesting is coerced. |
| `integer` | `int` only | Retained as a signed 64-bit integer across IPC and formatted in base 10; it never passes through a double. |
| `number` | `int`, `uint`, or `double` | Converted to a finite IEEE-754 double and formatted with compact decimal notation; NaN and infinities fail the cell. |
| `boolean` | `bool` only | Retained as a typed Boolean and displayed as `true` or `false`. |
| `quantity` | `string` only | Parsed with Kubernetes Quantity semantics. The exact quantity is retained and sorting uses Quantity comparison rather than lexical display or the approximate UI hint. |
| `timestamp` | CEL `timestamp` only | Retained as an instant and displayed as RFC 3339. |
| `duration` | CEL `duration` only | Retained as a duration and displayed with Go/CEL duration units such as `1h2m3s`. |

Null, `optional.none()`, or an absent optional uses the column's `missing`
text and has no typed sort value. A runtime type mismatch is a cell-local
error; Kmgr does not parse a formatted string to make it fit the declaration.
`resourceUsage` is reserved for native metric/accounting extractors and is not
a valid CEL result type.

Evaluation is deterministic and side-effect free. Each evaluation has a runtime cost limit (10,000 by default), a maximum of 128 list elements, and a 4 KiB rendered-value limit. Programs are compiled and type-checked when their definition/environment changes, then reused. Absent, null, and empty optional results render as `—` unless the definition supplies another missing value. Runtime failures belong to the individual column/cell and do not discard a row or view.

Sorting uses the typed result retained alongside display text. It never reparses formatted display text.

## Kubernetes server Table columns

For a resource without a curated native layout—most importantly a custom
resource—Kmgr negotiates the Kubernetes `meta.k8s.io/v1` (or v1beta1)
`metav1.Table` representation. The request sets `includeObject=Object`, so one
paginated LIST and its subsequent WATCH provide both:

- the CRD's `additionalPrinterColumns`/server printer values; and
- each full object required for selection, actions, filtering, CEL, and object
  details.

This is one stream for the requested GVR, not a companion discovery stream.
If Table negotiation is unsupported or a response is malformed, Kmgr disables
Table mode for that client and continues with the ordinary JSON LIST/WATCH for
the same GVR. It never opens a second resource merely to fill a column.

Kubernetes `Name`, `Namespace`, and `Age` Table columns are deduplicated against
Kmgr's native identity columns. Every remaining server column gets a stable,
collision-free `server-…` ID and a typed value based on its OpenAPI type and
format. Priority `0` columns are visible by default; higher-priority columns
are installed disabled but remain available in the Columns window. A changed
server schema is revisioned and applied without reopening the resource stream.

## Columns window

The native built-in/metric picker is filtered to the current resource GVR and
marks extractors already represented by the draft. It can add a catalog entry
disabled for deliberate review, or validate and add an exact Kubernetes
resource name such as `nvidia.com/gpu`. Definitions added by the user can be
removed; default and discovered definitions remain recoverable and are hidden
with their enabled checkbox instead. Reopening Columns with an unchanged draft
preserves the resource table's per-window drag order and resized widths. The
CEL editor compiles each current
revision through the engine and previews it against the selected table object
when exactly one is selected, otherwise against a bounded sample object. Only
the latest successful validation can be committed. A `?` help popover shows
common starting expressions (`object.metadata.name`,
`object.metadata.namespace`, `object.metadata.labels`, `object.metadata`,
`context.kind`, and `now`). If no row was selected before the window opened,
the editor explains that it is using a safe sample and suggests selecting one
item for a live-object preview. If an expression evaluates successfully but
has the wrong declared type, its complete raw value remains visible as YAML in
a bounded, scrollable preview beside the validation error; this is useful for
exploring maps and lists before choosing a scalar transformation.

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

Built-ins are validated against the exact GVR. Common metadata values are
`namespace`, `name`, `kind`, `labels`, `age`, `created`, and
`resourceVersion`. Resource-specific examples include Pod `ready`, `status`,
`restarts`, `pod-ip`, and `node`; Node `roles`, `taints`, `internal-ip`, and
`kubelet-version`; workload `desired`, `current`, `ready-count`, `up-to-date`,
and `available`; and the storage, networking, RBAC, CRD, and Event fields shown
by the Columns window. The resource-filtered native picker is the authoritative
catalog.

Metric values are `cpu`, `memory`, `ephemeral-storage`, and
`resource:<exact-resource-name>` for core/v1 Pods and Nodes. Qualified aliases
such as `pod.cpu.usageRequestLimit` and `node.cpu.usageAllocatable` resolve to
those same extractors. There are no Node request, limit, or Pod-count
extractors because those values would require watching Pods.

Native result types are part of the contract: counts such as `restarts`,
`taints`, `desired`, and `ready-count` are exact integers; `age` is a duration;
absolute time fields are timestamps; quantities retain Kubernetes Quantity
semantics; and metric values are `resourceUsage`.
Source, value, result type, and resource-kind compatibility are validated when
the configuration is compiled. CEL columns cannot declare `value`, and native
columns cannot declare a CEL expression.

Curated layouts follow the resource's operational question instead of using a
generic replica summary. Deployments show Ready, Up-to-date, and Available;
StatefulSets show Ready and Service; DaemonSets show Desired, Current, Ready,
Up-to-date, and Available; ReplicaSets and ReplicationControllers show Desired,
Current, and Ready. Selector, container, and image fields remain available but
are hidden by default.

The Node-only `roles` column sorts the suffixes of every
`node-role.kubernetes.io/<role>` label key and joins them with commas. `taints`
is the number of entries in `spec.taints`. A Node whose
`spec.unschedulable` is true appends `Unschedulable` to its readiness status,
for example `Ready,Unschedulable`. `internal-ip` and `external-ip` are separate
columns so an external address never silently substitutes for an internal
one. OS Image, architecture, kernel version, external IP, and ephemeral
storage are useful secondary Node fields and are hidden by default.

Pod and Node views use the built-in IDs `cpu`, `memory`, and
`ephemeral-storage`. Pods render actual usage / effective request / effective
limit; Nodes render actual usage / allocatable, with physical capacity in the
tooltip. These cells remain typed `resourceUsage` values even when actual usage
is unavailable. Node request and limit components are intentionally absent.
When usage pressure reaches the warning or critical threshold, only the actual
usage component is colored and emphasized; request, limit, and allocatable
values keep the normal contextual style.
CPU display values consistently use cores with compact precision: values of
ten or more use one fractional digit, while smaller values use at most two.
Memory, ephemeral storage, and each exact huge-page resource use the
largest readable binary unit (`Ki`, `Mi`, `Gi`, and so on), with up to two
fractional digits. Tooltips retain the exact canonical Kubernetes Quantity,
and sorting continues to use the unformatted typed numeric value.
Generic extended resources retain their canonical Quantity text because their
units are resource-specific counts rather than bytes.

`resourceUsage` sorting uses one documented numeric component rather than its
formatted triple. When measured usage exists, Kmgr sorts by usage/capacity,
falling back to usage/request, usage/limit, then raw usage when no denominator
exists. When usage is unavailable, allocation columns sort by
request/capacity, then limit/capacity; if those ratios cannot be formed, they
fall back in order to raw request, raw limit, then raw capacity. A value with
no usable component sorts as unavailable. Namespace, name, and UID remain the
stable deterministic tie-breakers.

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
Present huge-page entries are auto-added as disabled transient columns, while
present accelerator entries retain their enabled transient behavior;
configured-but-absent entries remain disabled. Ephemeral storage remains in
the existing built-in column instead of creating a duplicate exact-resource
column, and that built-in starts disabled in the default Pod and Node layouts.

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
