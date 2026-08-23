# Resource query language

The search field is the complete resource query. It is parsed once by
`kmgr-engine`; no additional selector or relationship filter is stored behind
the field. Whitespace-separated terms are combined with AND.

## Local terms

Bare terms search the visible cells, name, namespace, and status using a
case-insensitive substring match:

```text
api ready
```

Structured local terms are:

| Form | Meaning |
| --- | --- |
| `namespace:value` or `ns:value` | Namespace contains `value` |
| `name:value` | Name contains `value` |
| `status:value` | Typed status text contains `value` |
| `label:key` | Label key is present |
| `label:key=value` | Label value contains `value` (case-insensitive) |
| `label:key==value` | Label value exactly equals `value` (case-sensitive) |
| `field:path` | Projected field path is present |
| `field:path=value` | Field value contains `value` (case-insensitive) |
| `field:path==value` | Field value exactly equals `value` (case-sensitive) |

Single or double quotes preserve spaces, and a backslash escapes the next
character in local terms. Keys and field paths are exact and case-sensitive.

## Explicit Kubernetes selectors

Native Kubernetes selectors use explicit prefixes. Their contents are parsed
with Kubernetes' own selector parsers and are also checked locally against the
projected object:

```text
labelSelector:"app=api,track in (canary,stable),zone notin (east,west)"
fieldSelector:"spec.nodeName=worker-1"
```

`labelSelector:` accepts the Kubernetes label-selector grammar, including
`=`, `==`, `!=`, `in`, `notin`, bare-key existence, and `!key` absence.
`fieldSelector:` accepts the operators supported by Kubernetes field
selectors. Multiple native clauses are ANDed. They are the only query terms
sent as LIST/WATCH selectors; local `label:` and `field:` terms never become
implicit API filters.

The contents of an explicit native selector are passed to Kubernetes
unchanged, including Kubernetes backslash escapes such as `\,`, `\=`, and
`\\`. The surrounding query quote only groups the clause.

A malformed native selector is an inline query error. It is never silently
dropped or replaced with a broader query.

## Relationship drill-downs

Opening a workload's Pods, a node's Pods, or an object's Events writes its
complete native selector into the search field, for example:

```text
labelSelector:"app=api,track in (canary,stable)"
```

Editing or replacing that text edits the one query and therefore immediately
removes or changes the relationship constraint. History and window restoration
store the same visible query string.

## Per-resource query memory

Each workspace remembers the query by exact group, version, and resource.
Switching to an unseen resource starts with an empty query; returning to a
previously visited resource restores its last visible query.
