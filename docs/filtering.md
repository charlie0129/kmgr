# Resource query language

The search field is the complete resource query. It is parsed once by
`kmgr-engine`; no additional selector or relationship filter is stored behind
the field. Whitespace-separated terms are combined with AND.

While typing, the search field can complete reserved query prefixes and the
stable IDs of active projected columns. Completion is bounded to the current
query token: Tab accepts a suggestion, arrow keys move through suggestions,
Escape dismisses them, and Return keeps its normal apply-query behavior.
Accepting a value-bearing prefix inserts paired double quotes and leaves the
cursor between them (for example, `status:""`). The intermediate `column:`
prefix first completes a column ID, then inserts the quotes. Values are not
looked up or suggested, and native selector bodies remain opaque.

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

## Column-qualified terms

Bare terms search every selected column, including custom CEL, metric, and
server columns. A projected column can also be addressed directly using its
stable column ID:

```text
block:ready
column:block:ready
```

The short form is available when the column ID does not conflict with a
reserved query prefix (`namespace`/`ns`, `name`, `status`, `label`, `field`,
the native selector prefixes, or `column`). The explicit `column:` form is
always available for an active column, including IDs that conflict with a
reserved prefix. Column terms perform a case-insensitive substring match
against the column's rendered text and only address columns included in the
current view. Column IDs are case-sensitive; column titles are not query
names. Text-bearing terms (bare text, `name:`/`namespace:`/`status:`, and
column-qualified values) are emphasized in matching rendered cells; selector
bodies and local label/field predicates remain unstyled.

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

Opening a workload's Pods, a node's Pods, a Pod's assigned Node with `O`, or an
object's Events writes its complete native selector into the search field, for
example:

```text
labelSelector:"app=api,track in (canary,stable)"
fieldSelector:"metadata.name=worker-a"
```

Editing or replacing that text edits the one query and therefore immediately
removes or changes the relationship constraint. History and window restoration
store the same visible query string.

## Per-resource query memory

Each workspace remembers the query by exact group, version, and resource.
Switching to an unseen resource starts with an empty query; returning to a
previously visited resource restores its last visible query.
