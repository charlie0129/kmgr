# kmgr

`kmgr` is a keyboard-first, native macOS Kubernetes manager. It combines a
programmatic AppKit interface with an out-of-process Go engine built on
`client-go`; the UI stays focused on compact rows and window state while the
engine owns Kubernetes discovery, LIST/WATCH streams, caches, metrics,
mutations, logs, exec, and port-forwards.

The current build is an end-to-end developer release. It opens real kubeconfig
contexts and does not substitute static demo data.

## Requirements

- macOS 15 or later
- Xcode 16.4 or later, including the Swift 6.1 toolchain
- Go 1.26 or later
- A kubeconfig using static credentials, certificates, basic authentication,
  or another authentication form that does not invoke an external plugin

The macOS 15 deployment target is imposed by the maintained gRPC Swift 2 NIO
transport used for authenticated Unix-domain-socket IPC. The app is intended
for direct distribution and does not use App Sandbox.

## Build and run

```sh
make test      # run deterministic Go and Swift tests
make app       # assemble and ad-hoc sign build/Kmgr.app
make run       # build and launch the local app
make generate  # regenerate checked-in protobuf sources
```

`make app` defaults to a developer-friendly bundle with a SwiftPM Debug
executable and a Go helper that retains its symbol and DWARF data. It embeds
`kmgr-engine` under `Kmgr.app/Contents/Helpers`, signs the nested helper first,
then ad-hoc signs the bundle. It finishes with a strict offline check of bundle
metadata, executable layout, nested signatures, and the no-App-Sandbox policy.
No signing identity is required. The same verifier can inspect an existing
artifact with `./scripts/verify-app.sh`; the complete deterministic and
runtime-only release checklist is in
[docs/release-verification.md](docs/release-verification.md).

Use `CONFIGURATION=release make app` for a smaller distribution candidate. It
builds optimized Swift code, removes the copied Swift executable's symbol table
while leaving SwiftPM's separate dSYM under `macos/.build` for archival, and
builds the Go helper with `-s -w` while retaining `-trimpath` and the injected
version. All stripping happens before signing. A distribution pipeline can
archive the dSYM, replace both ad-hoc signatures with Developer ID signatures,
then add hardened-runtime and notarization steps.

`make generate` downloads pinned code generators into the ignored `.tools`
directory on first use. Ordinary builds use the generated Go and Swift files
already checked into the repository.

## Getting started

1. Launch Kmgr. The Cluster Manager reads normal kubeconfig resolution,
   including `KUBECONFIG` path lists and the default kubeconfig location,
   without contacting every listed server. When `KUBECONFIG` is unset, it also
   catalogs valid regular kubeconfig files directly inside `~/.kube` as
   independent sources. This makes sibling files such as `work.kubeconfig`
   discoverable without flat-merging same-named users, clusters, or credentials
   from an unrelated file.
2. Select a context and choose **Open**. This is the explicit connection
   boundary: the engine creates authenticated `client-go` clients and makes a
   short, deadline-bounded `GET /version` probe before accepting the session.
3. Pick a resource from the sidebar. Lists arrive progressively, then continue
   through WATCH. Moving away releases the last view consumer after a debounce;
   returning can display bounded warm rows immediately while the watch resumes
   or a relist runs in the background.
4. Use `/` for the current table filter and Command-K for commands, recent or
   cached objects, kinds, namespaces, or a two-stage resource-scoped object
   search. A scoped search checks compatible active/warm engine caches before
   doing a paginated LIST. When that LIST completes, its exact-scope snapshot
   can be handed once to the resource view, which displays those rows and
   resumes WATCH from the same resource version without repeating the LIST.

Each context workspace is a separate native window. Opening the same context
twice creates independent UI/navigation state while allowing the engine to
share compatible cluster authority. Details replace the table in that window;
logs and terminals use independent windows, and all forwards live in one
app-wide Port Forwards window.

## Main workflows

- Resource tables use UID-stable native multi-selection. Sorting, filtering,
  and watch updates do not retarget a selection by row index.
- Details provide a structured, copyable Summary table, plus YAML, Events,
  Relationships, Metrics where meaningful, and a Data editor for ConfigMaps
  and Secrets. Oversized Summary values stay available through row copy while
  their inline presentation remains bounded.
- `Y` opens the selected object's editable YAML tab inside Details. Shift-Y
  opens an independent, UID-pinned YAML window with an exact received-byte
  count, explicit refresh, and the same validated edit/apply workflow.
- YAML edits are parsed in Go, identity-checked, and dry-run as an exact
  material JSON Patch before the semantic diff is shown. UID/resourceVersion
  test operations prevent retargeting or stale writes, unchanged unknown fields
  are preserved, and force field ownership is unsupported.
- YAML viewing and editing use lightweight visible-range syntax colors for
  common keys, strings, numbers, booleans, nulls, and comments. Highlighting
  reads TextKit's existing backing store and caps each refresh independently of
  total document size.
- ConfigMap and Secret keys support text and raw binary values. Secret bytes
  are decoded/encoded by the engine and concealed by default in the UI.
- Logs support one or many UID-pinned Pods plus Deployments, StatefulSets,
  DaemonSets, ReplicaSets, Jobs, and CronJobs. A workload is resolved through
  UID-checked controller-owner hops to a bounded, static Pod snapshot; the
  window says that membership changes require reopening Logs. All Containers
  and common-container selection work across heterogeneous Pods. Container,
  follow, previous logs, timestamps, tail, and since remain adjustable in the
  live window toolbar alongside filtering, pause, copy, and explicit save. The
  context and exact source labels remain visible above the bounded log buffer.
  Oversized logical lines show only a marked 4 KiB preview by default, so
  TextKit never installs or lays out a multi-megabyte line. Save preserves the
  buffered logical line without display-only truncation markers or breaks.
- Pod exec uses a SwiftTerm window and direct argv transport. `S` automatically
  chooses the annotated/default regular container and probes `/bin/bash` then
  `/bin/sh`; Shift-S opens configuration for choosing a container or running an
  explicit executable without shell parsing.
- Pod and Service port-forwards bind loopback by default and retry with
  exponential backoff capped at 15 seconds until explicitly stopped. A direct
  Pod forward rechecks its pinned UID before every retry. If the Pod was
  deleted and a same-name Pod appears with a new UID, the forward stays
  **Failed** and never attaches to the replacement. Service forwards may
  resolve another eligible Pod.
- Delete, scale, rollout restart, label/annotation editing, and copy actions
  are exposed through native menus. Deletes carry UID preconditions and report
  per-object partial failures.

### Relationships and scan cost

Opening **Relationships** is intentionally cheap by default. It gets owners
authoritatively and reads child relationships only from resource caches the
engine already has; it never wakes stopped watches or lists every resource
kind. The UI labels these child results **Cached children · potentially
incomplete**, including when no cached children were found.

Choose **Scan All Resources…** only when fuller coverage is worth the API cost.
After confirmation, Kmgr performs cancellable, paginated metadata LISTs across
discovered listable resource types and reports progress. The result can still
be marked potentially incomplete when discovery is partial or RBAC denies a
resource. The scan anchors the target's exact UID before doing bulk reads.

## Keyboard reference

Single-letter commands apply only while the resource table is first responder,
so they do not steal input from filters, YAML/data editors, logs, or terminals.
Kmgr also keeps one passive **Shortcuts** panel above its windows while the app
is active. The panel follows the active leaf view (including resource filters,
Pod containers, object Data, and the Cluster Manager), never takes keyboard
focus, and hides when no supported context is active.

| Binding | Action |
| --- | --- |
| Command-N | Open a new Cluster Manager window |
| Command-K | Open the current workspace's Command Palette |
| Shift-Command-N | Open the current workspace's namespace picker |
| `/` | Focus the resource filter |
| Up / Down, `K` / `J` | Move table selection |
| Shift-click / Shift-Up / Shift-Down | Extend native selection |
| Command-click | Toggle one selected row |
| Command-A | Select all visible rows |
| Return | Enter a useful subresource, such as Pod containers or workload Pods |
| Command-Return | Open details for exactly one object |
| Command-[ / Command-] | Back / Forward |
| Escape | Clear selection or return focus to the table |
| `Y` | Open the YAML tab in Details for one object |
| Shift-Y | Open YAML for one object in an independent window |
| `E` | Open Events for one object |
| `L` | Tail all containers for compatible selected Pods or workloads |
| Shift-L | Show logs from the previous container instance for compatible selected Pods or workloads |
| `S` | Open a terminal for one Pod using automatic container and shell defaults |
| Shift-S | Configure the container, shell, or executable for one Pod |
| `P` | Configure a port-forward for one Pod or Service |
| Command-Backspace | Confirm deletion of selected resources |
| Command-S | Save the active YAML or key/value edit |

Standard AppKit text editing, copy, undo/redo, find, and window behavior remain
with the focused native control.

Both YAML surfaces use the native Command-F find bar. While editing YAML,
unmodified letters always enter the document and standard Command shortcuts
provide find, copy, paste, undo, redo, and save.

In a Pod's Containers subresource, `L`/Return opens the selected container's
current logs, Shift-L opens its previous container instance's logs, `S` opens
its terminal, Shift-S configures its terminal, and `P` starts a port-forward
for the UID-pinned parent Pod.

## Programmable columns and filtering

Column definitions live at:

```text
~/Library/Application Support/kmgr/columns.yaml
```

The schema is `kmgr.charlie0129.dev/v1alpha1` and the independently versioned
CEL environment is `kmgr.cel/v1`. The Columns window can enable and reorder
definitions, choose GVR-compatible built-in or metric extractors from a native
catalog, enter exact scheduler resources, add or edit CEL definitions, preview
CEL against the selected object or a bounded sample, reset defaults, and
persist definitions. Draft order and visibility apply live to the table.
Programmers can edit the same YAML file outside the app. The engine loads the
configured path when it starts, so after external edits relaunch Kmgr to reload
the engine configuration.

The complete external file schema and example, CEL activation, optional-field
syntax, types, cost/output limits, Secret sanitization boundary, and exact
huge-page/accelerator resource handling are documented in
[docs/columns.md](docs/columns.md). The table filter grammar and structured
terms are documented in
[docs/filtering.md](docs/filtering.md).

Metrics are optional enrichment. Pod and Node CPU/memory usage is fetched
lazily from `metrics.k8s.io`; absence or RBAC denial leaves base objects and
Pod scheduler request/limit accounting available. Configured Node allocation
columns for CPU, memory, ephemeral storage, Pod count, huge pages, and exact
accelerator resources start a shared cluster-wide Pod dependency
asynchronously, initially render **Calculating…**, and update as bound Pods
change without delaying the base Node list. Exact configured huge-page and
accelerator keys remain distinct.

After a Pod or Node base snapshot is usable, Kmgr queries a cache-only catalog
for exact huge-page and accelerator resources and automatically installs
present resources as transient columns. Ephemeral storage remains represented
by its richer built-in column rather than a duplicate exact-resource column.
If a later Pod or Node update introduces a previously unseen exact scheduler
resource, a bounded stream hint repeats the authoritative cache-only query so
a cold empty snapshot cannot permanently hide that column.
Base-list delivery never waits for catalog or Kubernetes API I/O, discovery
does not change base-list freshness, persisted definitions win over transient
matches, and the transient overlay is scoped to the current helper session and
exact GVR rather than written to `columns.yaml`.

## Architecture and security

```text
Kmgr.app (AppKit)
    compact rows, windows, responders, selection by UID
            │ authenticated gRPC over a private Unix socket
            ▼
kmgr-engine (Go/client-go)
    kubeconfig, objects, watches, CEL, metrics, mutations, streams
            │ authenticated Kubernetes HTTP transports
            ▼
Kubernetes API server
```

The app creates a short per-launch directory with mode `0700`, places a Unix
socket inside it with user-only access, and gives the helper a random launch
token. Every RPC carries that token. The GUI supervises one helper and removes
the private endpoint on shutdown; a helper crash cannot corrupt the AppKit
process. After an unexpected helper restart, visible workspaces reopen their
context through the normal authenticated probe and rebind safe resource and
UID-pinned detail views to the new session. Cached table rows remain visibly
disconnected and cannot perform network actions until a complete fresh UID
snapshot validates them. Mutations and exec commands are never replayed, and
old helper-owned port-forwards remain visible as failed records rather than
being recreated silently.

The helper runs as the current user without privilege escalation. Its only
management endpoint is the private Unix socket; Kmgr does not expose a TCP or
other network-accessible management API. Kubernetes operations use pinned
`client-go` APIs and structured arguments—Kmgr never constructs or shells out
to `kubectl` commands.

Kmgr does not copy kubeconfig credentials into app storage. It rejects
`users[].user.exec` and legacy `auth-provider` entries before connection and
never invokes cloud CLIs or custom credential programs. It also does not
provide an ignore-TLS switch.

Diagnostics contain RPC method, duration, status, and safe structural context;
they must not contain bearer tokens, client keys, Secret contents, exec I/O,
log records, or full mutation payloads. Secret plaintext, log buffers, and
terminal buffers are excluded from restoration. Port-forwards default to
`127.0.0.1`; broader binds require explicit confirmation.

## State and diagnostics

Versioned UI settings and column configuration are kept under
`~/Library/Application Support/kmgr/`. Lightweight window/navigation state is
restored, but warm object caches remain process-memory-only and are never
presented as restored cluster truth after relaunch.

Warm resource stores are governed by three independent LRU ceilings. Defaults
are 24 views, 250,000 objects, and a conservative 512 MiB retained-size
estimate process-wide, plus 8 views, 100,000 objects, and 192 MiB for each
cluster authority. Crossing any ceiling evicts the least recently used store;
one store larger than a whole ceiling is not admitted. The byte estimate covers
the immutable unstructured object graph, UID-store indexes, and any compact
projected row graph retained for immediate stale first paint, all with safety
overhead. If compact rows alone make an otherwise fitting entry exceed an
individual byte ceiling, kmgr drops those optional rows and retries raw-store
admission; a raw store that itself exceeds a ceiling is not retained. The
estimate is intentionally conservative and is neither an RSS measurement nor a
promise that the Go allocator will return the same number of bytes to the
operating system immediately after eviction.

The engine emits structured, redacted JSON diagnostics on stderr. The GUI
normally drains that stream without mirroring raw text into application logs.
To inspect actual helper RPC timing from a terminal without persisting it, run:

```sh
KMGR_ENGINE_LOG_LEVEL=debug build/Kmgr.app/Contents/MacOS/Kmgr
```

Accepted levels are `debug`, `info`, `warn`, and `error`; any other value is
ignored and retains the normal drained-stderr behavior. Set `KMGR_ENGINE_PATH`
to an absolute local engine executable in the same command to test a separately
built helper. Debug app builds also contain an opt-in, loopback-only Go
profiler; it is absent from Release helpers and is documented with the
performance harness in
[docs/performance.md](docs/performance.md).

Resource-list cache diagnostics are separately opt-in because they include the
resource GVR, namespace scope, and the first/last object names in received
snapshots. They never include UIDs, object contents, filter text, kubeconfig
data, or credentials. Quit any already-running Kmgr process, then launch the
diagnostic build directly from a terminal:

```sh
KMGR_RESOURCE_CACHE_DIAGNOSTICS=1 build/Kmgr.app/Contents/MacOS/Kmgr
```

After reproducing, export only the dedicated unified-log category:

```sh
/usr/bin/log show \
  --last 15m \
  --style compact \
  --info --debug \
  --predicate 'process == "Kmgr" AND subsystem == "com.pktium.kmgr" AND category == "resource-cache"' \
  > "$HOME/Desktop/kmgr-resource-cache.log"
```

The trace records navigation and reopen reasons, context comparisons, retained
row counts, every status/snapshot/delta decision, and the exact operation that
replaced a non-empty table with zero rows.

## Testing

`make test` requires no real Kubernetes cluster. It uses fake clients,
`httptest` API fixtures, deterministic stream doubles, and AppKit-independent
Swift reducers. It also launches a real Go helper through an isolated private
Unix socket to verify Swift authentication, bad-token rejection, crash restart,
and endpoint cleanup without reading kubeconfigs or contacting a cluster. This
includes LIST/WATCH continuity, 410 relists, cache
retention/eviction, UID replacement safety, Secret sanitization, CEL limits,
resource accounting, bounded streams, port-forward reconnects, and a 100,000
row synthetic model plus native `NSTableView` harness. Targeted AppKit tests
also pin the resource workspace's accessibility roles/text alternatives and
the Relationships view's potentially-incomplete default with its explicit
expensive-scan action.

For a manual smoke test, provide the exact disposable context name and
explicitly authorize the test scope first. Merely making a context available
authorizes read-only checks; it does not authorize creating or deleting test
objects. With separate approval, mutation tests should be isolated to a
temporary `kmgr-smoke` namespace in a disposable cluster. Then:

1. Open two windows, then list, filter, and sort Pods independently.
2. Open Nodes, switch away long enough for its watch debounce, verify the Nodes
   WATCH actually stops after the last consumer leaves, then return and verify
   cached rows appear while state changes through Resuming or Relisting.
3. Create a multi-selection with a Shift anchor, cause updates that reorder the
   sorted rows, and verify the selected UIDs and anchor still identify the same
   objects rather than the same row indexes.
4. Exercise Command-K commands, recent/cached root object matches, and kinds,
   then choose the Pod search entry and exercise an exact object GET and scoped
   partial search. Complete a paginated search, open its resource view, and
   verify the completed snapshot supplies the initial rows before WATCH without
   a duplicate LIST. Verify cached search does not restart a stopped watch and
   that object search stays within the selected kind/scope: it must not perform
   an all-resource search or start a search-only WATCH.
5. Open independent log windows for one and multiple Pods, then an exec window.
6. Start a Service forward, hide its manager and close its workspace, verify it
   remains active and reconnects, then stop it explicitly.
7. Start a direct Pod forward, replace that Pod with the same name/new UID, and
   verify the record remains Failed rather than switching identity.
8. Edit a ConfigMap key and a decoded Secret key; exercise a YAML
   resource-version conflict.
9. If mutation authorization was given, bulk-delete only approved disposable
   objects in `kmgr-smoke` and verify partial results/UID preconditions.
10. View both Pod and Node metrics, then compare their behavior with Metrics API
    available and unavailable. Enable configured Node request/limit and
    exact-resource columns, verify discovered huge-page/accelerator columns
    appear after the base snapshot, and confirm asynchronous Pod accounting
    does not block that snapshot.
11. In Relationships, verify cached results are labeled potentially incomplete;
    run **Scan All Resources…** only against a cluster where that read load is
    acceptable.
12. While a safe resource or detail view is visible, terminate the helper and
    verify the workspace shows a disconnected state, reopens through a fresh
    authenticated session, and does not replay mutations, exec commands, or
    port-forwards.

A real smoke run requires an explicit context name and begins read-only.
Creating/deleting the `kmgr-smoke` namespace or anything inside it requires
separate authorization. Use a disposable cluster and least-privilege
credentials; the relationship scan can issue LIST requests across every
discoverable listable type.

## Known limitations

- macOS only; the native UI requires macOS 15 with the current dependency set.
- External kubeconfig exec plugins and legacy auth-provider integrations are
  deliberately unsupported in v1.
- Supported workloads resolve to a bounded, UID-pinned static Pod snapshot;
  following dynamic workload membership is not implemented.
- Exec reconnect starts a new process; it cannot preserve the original remote
  process.
- Relationship cache results are deliberately incomplete by default, and even
  an explicit full scan is limited by discovery and RBAC visibility.
- Port-forwards and other live sessions are not restored after an app relaunch.
  An unexpected helper restart reopens safe cluster resource/detail views, but
  it does not replay mutations or exec commands; old forwards become failed
  tombstones. Confirmed application quit stops active listeners.
- Metrics Server generally does not provide accelerator, huge-page, or
  ephemeral-storage utilization. Kmgr labels scheduler allocation separately
  and does not manufacture usage.

## Troubleshooting

- **A context is disabled:** inspect the authentication label. `exec` and
  `auth-provider` kubeconfig users are rejected intentionally; use a supported
  static/test context rather than asking Kmgr to invoke a cloud CLI.
- **Open fails:** the authenticated `/version` probe has an eight-second
  deadline. Check the server hostname, VPN/network, credential validity, CA,
  and kubeconfig TLS server-name settings. The failed provisional session is
  closed rather than leaving an apparently connected window.
- **No rows or a reconnecting banner:** keep the cached table visible and read
  the connection/watch state. A stale resource version can cause a background
  relist without blanking usable warm rows.
- **Metrics show Unavailable:** grant read access to `metrics.k8s.io` or install
  a compatible Metrics Server. Base LIST/WATCH remains independent.
- **A relationship is missing:** cached results are expected to be potentially
  incomplete. Use **Scan All Resources…** if the added cluster-wide reads are
  acceptable; failures listed during that scan usually indicate RBAC or partial
  discovery.
- **A forward stays Failed after Pod replacement:** this is the UID safety
  contract. Start a new forward explicitly for the replacement Pod.
- **Column configuration fails to load:** verify both version strings and use
  the Settings window to confirm the active path. Invalid files produce an
  explicit configuration error rather than changing CEL meaning silently.
