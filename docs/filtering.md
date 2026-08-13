# Resource filter grammar

The resource-list filter is deliberately small and deterministic. It is parsed and evaluated by `kmgr-engine`; it never invokes a shell or evaluates a scripting language.

Whitespace-separated terms are combined with AND. Bare terms match a case-insensitive substring in the visible cells, name, namespace, or status. Single or double quotes preserve spaces, and a backslash escapes the next character.

Structured terms are:

| Form | Meaning |
| --- | --- |
| `namespace:value` or `ns:value` | Namespace contains `value` |
| `name:value` | Name contains `value` |
| `status:value` | Typed status text contains `value` |
| `label:key` | Label key is present |
| `label:key=value` | Label key is present and its value contains `value` |
| `field:path` | Projected field path is present |
| `field:path=value` | Projected field path is present and its scalar text contains `value` |

Keys and field paths are exact and case-sensitive; values use case-insensitive substring matching. An unknown prefix, missing key/value, unterminated quote, or trailing escape is a parse error. The UI keeps the query visible and reports that error inline while retaining the last valid result set.

Examples:

```text
api status:running
namespace:"team platform" label:app=controller
field:spec.nodeName=worker-3
```

## Per-resource filter memory

Each workspace remembers the current filter by exact group, version, and
resource. Switching to a GVR not visited in that window starts with an empty
filter, so a Pod query cannot silently filter Nodes. Returning to a previously
visited GVR restores that resource's last filter.
