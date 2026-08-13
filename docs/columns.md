# Programmable columns

Column definitions are stored at `~/Library/Application Support/kmgr/columns.yaml`. The file schema starts at `kmgr.charlie0129.dev/v1alpha1`; the independently versioned CEL environment is `kmgr.cel/v1`. A definition must declare its result type. Changing expression semantics requires a new environment version and an explicit migration error rather than silent reinterpretation.

## `kmgr.cel/v1` activation

- `object`: dynamic Kubernetes object. For Secrets, the engine constructs a sanitized copy with top-level `data` and `stringData` removed before CEL receives it.
- `metrics`: dynamic, non-sensitive computed metrics/accounting values. Exact huge-page and accelerator resource names remain separate map keys.
- `context`: dynamic non-sensitive GVR, namespace-scope, and view metadata.
- `now`: one CEL timestamp captured once for an entire projection batch.

CEL optional syntax is enabled. For example:

```cel
object.?spec.?nodeName.orValue("—")
object.?metadata.?labels[?"team"].orValue("—")
```

The supported declared types are `string`, `integer`, `number`, `boolean`, `quantity`, `timestamp`, and `duration`. Quantity values currently use their exact Kubernetes quantity string; typed native quantity and resource-usage results are provided by built-in metric columns. A string column may accept a list of scalar values, joined by its configured separator.

Evaluation is deterministic and side-effect free. Each evaluation has a runtime cost limit (10,000 by default), a maximum of 128 list elements, and a 4 KiB rendered-value limit. Programs are compiled and type-checked when their definition/environment changes, then reused. Absent, null, and empty optional results render as `—` unless the definition supplies another missing value. Runtime failures belong to the individual column/cell and do not discard a row or view.

Sorting uses the typed result retained alongside display text. It never reparses formatted display text.
