# kmgr

`kmgr` is a keyboard-first, native macOS Kubernetes manager. It combines a
programmatic AppKit interface with an out-of-process Go engine built on
`client-go`; the UI stays focused on compact rows and window state while the
engine owns Kubernetes discovery, LIST/WATCH streams, caches, metrics,
mutations, logs, exec, and port-forwards.

## Requirements

- macOS 15 or later
- Xcode 26 or later
- Go 1.26 or later
- A kubeconfig using static credentials, certificates, basic authentication,
  or a non-interactive `exec` credential plugin

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
`kmgr-engine` under `Kmgr.app/Contents/Helpers` and compiles `assets/kmgr.icon`
into a Tahoe `Assets.car` plus a pre-Tahoe `kmgr.icns` fallback. It signs the
embedded Swift back-deployment runtime and helper first, then ad-hoc signs the
bundle. The app and helper versions both use the build's
`git describe --always --dirty` value. It finishes with a strict offline check
of bundle metadata, both application-icon resources, executable and
runtime-library layout, nested signatures, and the no-App-Sandbox policy. No
signing identity is required. The same verifier can inspect an existing
artifact with `./scripts/verify-app.sh`; the complete deterministic and
runtime-only release checklist is in
[docs/release-verification.md](docs/release-verification.md).

Use `make app-release` for a smaller distribution candidate. It
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
   from an unrelated file. Use **Kubeconfig Files…**, Command-O, or drag files
   onto the context table to add kubeconfigs elsewhere. Kmgr remembers only
   their standardized paths, loads each as an independent source, and reports
   missing or malformed remembered files without hiding healthy contexts.
2. Select a context and choose **Open**. This is the explicit connection
   boundary: the engine creates authenticated `client-go` clients and makes a
   short, deadline-bounded `GET /version` probe before accepting the session.
3. Pick a resource from the sidebar. Lists arrive progressively, then continue
   through WATCH. Moving away releases the last view consumer after a debounce;
   returning can display bounded warm rows immediately while the watch resumes
   or a relist runs in the background. If that resource remains stuck
   reconnecting, choose **Resource → Restart Resource Stream** or press
   Command-R. The action preserves the current scope, filter, columns, and sort
   while discarding the retained resource version and starting a fresh
   LIST/WATCH lifecycle. Metric-backed filters and sorts publish their base-field
   result first; the status briefly shows `Updating metrics…` while metric-only
   matches and the exact metric order are refined.
4. Use `/` for the current table filter and Command-K for commands, recent or
   cached objects, kinds, namespaces, or a two-stage resource-scoped object
   search. A scoped search checks compatible active/warm engine caches before
   doing a paginated LIST. When that LIST completes, its exact-scope snapshot
   can be handed once to the resource view, which displays those rows and
   resumes WATCH from the same resource version without repeating the LIST.
   Ordinary keywords and column expressions remain local table filters; only
   explicit `labelSelector:` and `fieldSelector:` terms become Kubernetes API
   selectors.

Each context workspace is a separate native window. Opening the same context
twice creates independent UI/navigation state while allowing the engine to
share compatible cluster authority and warm cache state. Details and YAML are
dedicated utility windows, so the resource table remains visible while `D`
opens Details and `Y` opens YAML. `E` opens or focuses the YAML utility and
starts editing. Logs and terminals use independent windows, and all forwards
live in one app-wide Port Forwards window.

## Main workflows

- Resource tables use UID-stable native multi-selection. Sorting, filtering,
  and watch updates do not retarget a selection by row index. Drag across rows
  or use Shift-click to select a contiguous range; Command-click toggles one
  row. Clicking a cell captures its full value for Command-C or Copy Cell
  without adding a second visible selection or changing the selected rows.
- Restarting a resource stream affects that compatible shared raw stream, not
  the entire cluster connection. Other resource kinds, mutations, terminals,
  logs, and port-forwards continue independently.
- Details provide a structured Summary table where clicking a cell and pressing
  Command-C (or choosing Copy Cell from its context menu) copies the complete
  value. A Pod Summary reports the reason, exit code, and relative and local
  absolute finish times for its most recent container restart when Kubernetes
  provides them.
  Labels and Annotations remain visible as separate sections even when empty;
  each has its own editor, and Return on a selected metadata row opens that kind
  with the key selected. The metadata and ConfigMap/Secret Data editors use the
  same searchable, draggable key/value split view, keyboard
  behavior, structured-text highlighting, whitespace markers, staged row
  states, and save review while keeping their validation rules separate. The
  dedicated YAML utility handles object viewing and editing, with the
  API-managed `metadata.managedFields` field omitted. ConfigMap/Secret Data is
  the complete Return-driven key/value viewer and
  editor. Oversized Summary values,
  including metadata values, stay available through cell copy while their
  inline presentation remains bounded to one line.
- When core/v1 Events are listable, Details appends up to the 10 most recent
  UID-filtered Events to Summary. They load after the object Summary is visible
  and never block it. Press `E` in Details Summary to open the complete
  sortable, virtualized live Events list in a new full workspace.
- Press `P` on a selected resource to follow its immediate Kubernetes owner in
  the current workspace, or Command-P to open that parent in a new workspace.
  Kmgr prefers the unique controlling owner, otherwise follows the sole live
  owner, and warns instead of guessing when references are absent, stale, or
  ambiguous. The destination list uses a visible exact
  `fieldSelector:"metadata.name=…"` server-side query and auto-selects only
  the referenced UID, never a same-name replacement.
- Press `O` on a selected Pod to show its assigned Node in the current
  workspace, or Command-O to open that Node list in a new workspace.
- `Y` opens an independent, UID-pinned read-only YAML utility; `E` opens or
  focuses that same utility and immediately enters editing. The YAML utility
  has an exact received-byte count, explicit refresh, and the validated
  edit/apply workflow.
- YAML edits are parsed in Go, identity-checked, and dry-run as an exact
  material JSON Patch before the semantic diff is shown. UID/resourceVersion
  test operations prevent retargeting or stale writes, unchanged unknown fields
  are preserved, and API-managed `metadata.managedFields` stays out of the
  editor and kmgr's patch, while force field ownership is unsupported.
- YAML viewing and editing use lightweight visible-range syntax colors. Shared
  key-value editors apply the same YAML colors to `.yml`/`.yaml` keys and
  best-effort JSON colors to object or array values, including nested annotation
  values. Spaces, tabs, line endings, and other control characters in YAML and
  text values use quiet editor-style TextKit whitespace markers; the text
  portions of YAML and key-value diff reviews use the same markers. Unified
  diff prefixes, headers, synthetic line separators, and binary previews keep
  their ordinary presentation. These markers are presentation only, so the
  stored bytes, accessibility value, copy/paste, and undo history remain
  unchanged. Highlighting reads TextKit's existing backing store and caps each
  refresh independently of total document size.
- ConfigMap and Secret keys support text and raw binary values. Add, edit,
  rename, and delete operations stay local until **Save Changes**. Data search
  matches complete keys, text values, and staged drafts rather than only the
  bounded row preview. Saving opens a master-detail review: the left side lists
  every Added, Modified, Renamed, or Deleted key with before/after summaries;
  the right side lazily renders the selected value. Text uses contextual unified
  hunks and binary data uses aligned changed-byte rows. Oversized comparisons
  show bounded context around the actual change while complete values remain the
  atomic batch mutation input. Secret bytes are
  decoded/encoded by the engine and concealed by default; revealing them
  explicitly also enables value search and decoded diff review, while
  concealing them clears transient queries and presentations. The UI never
  asks the user to decode or encode base64.
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
- Pod and Service port-forwards bind loopback by default. The local port starts
  at the selected remote port; if that listener is occupied, the engine tries
  bounded `+10,000` fallbacks and finally asks the OS for a free port. Forwards
  retry with exponential backoff capped at 15 seconds until explicitly
  stopped. A direct Pod forward rechecks its pinned UID before every retry. If
  the Pod was deleted and a same-name Pod appears with a new UID, the forward
  stays **Failed** and never attaches to the replacement. Service forwards may
  resolve another eligible Pod.
- Delete, scale, rollout restart, separate Edit Labels and Edit Annotations
  actions, and copy actions are exposed through native menus. Metadata editors
  load an authoritative UID/resourceVersion and submit one sparse optimistic
  mutation. Label, annotation, ConfigMap, and Secret editors preserve failed or
  conflicted batches for another review, and prompt before discarding staged
  changes on close or Back. Deletes carry UID preconditions and report
  per-object partial failures.

## Keyboard reference

Resource-table single-letter commands apply only while that table is first
responder. Details, YAML, and other leaf views expose their own
contextual letters without stealing input from editable controls, filters,
logs, or terminals.
Kmgr also keeps one passive **Shortcuts** panel above its windows while the app
is active. The panel follows the active leaf view (including resource filters,
Pod containers, Data and metadata key/value editors, and the Cluster Manager),
never takes keyboard focus, and hides when no supported context is active. It
is shown by default on first launch. Close the panel or use
**Window → Hide Shortcuts** to disable it;
**Window → Show Shortcuts** enables it again. Kmgr remembers this choice
globally across launches rather than per cluster.

| Binding | Action |
| --- | --- |
| Command-N | Open a new Cluster Manager window |
| Command-H | Hide Kmgr |
| Command-? | Open Kmgr Help |
| Control-Command-S | Show or hide the current workspace's sidebar |
| Control-Command-F | Enter or leave full screen |
| Command-O in Cluster Manager | Add kubeconfig files |
| `/` in Cluster Manager | Search kubeconfig contexts |
| Command-K | Open the current workspace's Command Palette |
| Shift-Command-N | Open the current workspace's namespace picker |
| `/` | Focus the resource filter |
| Command-R | Restart the current resource's LIST/WATCH stream |
| `/` or Command-F in a key/value editor | Search keys and values |
| Return in a key/value editor | Edit the selected value |
| Return in Details Summary | Edit the selected label or annotation |
| Up / Down, `K` / `J` | Move table selection |
| Drag across rows / Shift-click / Shift-Up / Shift-Down | Extend native selection |
| Command-click | Toggle one selected row |
| Command-A | Select all visible rows |
| `O` | Show the selected Pod's assigned Node in the Node list |
| Command-O | Show the selected Pod's assigned Node in a new full workspace |
| `D` | Open or focus Details in a utility window for exactly one object |
| Return | Enter a useful subresource in the current workspace |
| Command-Return | Enter the selected subresource in a new full workspace |
| `P` | Go to the selected object's immediate Kubernetes owner |
| Command-P | Go to the selected object's owner in a new full workspace |
| Command-click in the sidebar | Open the selected resource in a new full workspace |
| Command-[ / Command-] | Back / Forward |
| Escape | Clear selection or return focus to the table |
| `Y` | Open or focus the read-only YAML utility for one object |
| `E` in a resource table | Open or focus the YAML utility and start editing |
| `E` in the YAML utility | Start editing the YAML |
| `E` in Details Summary | Open the complete object Events list in a new workspace |
| `L` | Tail all containers for compatible selected Pods or workloads |
| Shift-L | Show logs from the previous container instance for compatible selected Pods or workloads |
| `S` | Open a terminal for one Pod using automatic container and shell defaults |
| Shift-S | Configure the container, shell, or executable for one Pod |
| `F` | Configure a port-forward for one Pod or Service |
| Command-F in a resource or Pod-container table | Configure a port-forward, then show Port Forwards after it starts |
| Command-Backspace | Confirm deletion of selected resources |
| Command-S | Save the active YAML or key/value edit |

Standard AppKit text editing, copy, undo/redo, find, and window behavior remain
with the focused native control.

The YAML utility uses the native Command-F find bar. While editing YAML,
unmodified letters always enter the document and standard Command shortcuts
provide find, copy, paste, undo, redo, and save.

In a Pod's Containers subresource, `L`/Return opens the selected container's
current logs, Shift-L opens its previous container instance's logs, `S` opens
its terminal, Shift-S configures its terminal, `F` starts a port-forward for
the UID-pinned parent Pod, and Command-F shows Port Forwards after a successful
start. `P` is reserved for resource-list parent navigation and is unbound here.

New Pod terminals and Node shells open at 120 columns by 35 rows by default.
Settings can choose an initial size from 80–300 columns and 20–100 rows;
already-open terminal windows keep their current independently resizable size.

## Programmable columns and filtering

Column definitions live at:

```text
~/Library/Application Support/kmgr/columns.yaml
```

The schema is `kmgr.chlc.cc/v1alpha1` and the independently versioned
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
[docs/columns.md](docs/columns.md). The table query language, including local
terms and explicit Kubernetes selectors, is documented in
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
the private endpoint on shutdown. Each supervised launch also opts into a
parent-liveness standard-input pipe: if Kmgr crashes, is force-killed, or exits
before its normal shutdown handshake, pipe EOF makes the engine run the same
bounded cleanup used for signals and RPC shutdown. Standalone engine launches
do not monitor standard input unless `--parent-liveness-stdin` is explicitly
set. A helper crash cannot corrupt the AppKit process. After an unexpected
helper restart, visible workspaces reopen their
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

Kmgr does not copy kubeconfig credentials into app storage. User-added
kubeconfigs remain in place; only their absolute paths are persisted, and
removing one from Cluster Manager never deletes the file. Kmgr supports
non-interactive `users[].user.exec` credential plugins and invokes them only
after a context is explicitly opened. A bounded login-zsh probe supplies the
user's normal command search path; the selected executable then runs through a
short-lived engine proxy with the connection deadline, bounded output, no
terminal input, and process-group termination. Legacy `auth-provider` entries
remain rejected. Opening an exec-auth context therefore trusts its kubeconfig
command to run with the current user's privileges, just as opening it with
`kubectl` would. Kmgr also does not provide an ignore-TLS switch.

Application diagnostics contain RPC method, duration, status, and safe
structural context; they must not contain bearer tokens, client keys, Secret
contents, exec I/O, workload log records, or full mutation payloads. Secret
plaintext, log buffers, and terminal buffers are excluded from restoration.
Port-forwards default to `127.0.0.1`; broader binds require explicit
confirmation.

## State and diagnostics

Versioned UI settings and column configuration are kept under
`~/Library/Application Support/kmgr/`. Lightweight window/navigation state is
restored, but warm object caches remain process-memory-only and are never
presented as restored cluster truth after relaunch.

Cluster workspace frames are remembered independently as signed global
coordinates, so a window on a display to the left or below the primary display
can be restored without a physical display identifier. On relaunch, each
restored workspace uses its own last size and position when that frame still
intersects a current display; an unavailable or invalid frame gets a visible
fallback. When a new workspace is opened, an exact kubeconfig context with
prior frame history starts from that context's frame. If another visible window
occupies that frame, kmgr first tries to place the new window beside it on the
same display and otherwise uses a small cascade on that display; it does not
move to another display merely to avoid overlap. An unavailable bookmark
prefers the display of the current source window, while an unseen context uses
the global last workspace size and a visible cascade. Frames are checkpointed
while a window moves or resizes, not only when it closes. Closing a workspace
removes only its open-window record; the exact-context frame history remains
available for a later new window.

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

The engine emits structured, redacted JSON diagnostics on stderr. Kmgr always
drains that stream into a bounded, process-memory-only tail (20,000 records and
16 MiB by default). The current generation is available while the helper is
running; after an unexpected exit, the latest unexpected generation and its
termination metadata remain available until a later unexpected generation
replaces it. Engine diagnostics are not written to disk and are not forwarded
to OSLog.

Open **Window → Engine Diagnostics…** to inspect the retained tail. The window
supports filtering, wrapping, and refresh; press **W** to toggle line wrapping.
After a successful recovery, the workspace footer shows a non-clickable
**Engine restarted unexpectedly** warning with the same menu path. If restart
recovery exhausts its attempts, Kmgr opens the diagnostics window automatically.

To additionally mirror redacted helper RPC timing to a terminal, launch the
app with an explicit log level:

```sh
KMGR_ENGINE_LOG_LEVEL=debug build/Kmgr.app/Contents/MacOS/Kmgr
```

Accepted levels are `debug`, `info`, `warn`, and `error`; any other value is
ignored. The terminal mirror is an explicit diagnostic tee; the in-memory tail
continues to be captured at the same time. Set `KMGR_ENGINE_PATH` to an
absolute local engine executable in the same command to test a separately
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
  --predicate 'process == "Kmgr" AND subsystem == "cc.chlc.kmgr" AND category == "resource-cache"' \
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
parent-death cleanup, standalone liveness opt-in, and endpoint cleanup without
reading kubeconfigs or contacting a cluster. This
includes LIST/WATCH continuity, 410 relists, cache
retention/eviction, UID replacement safety, Secret sanitization, CEL limits,
resource accounting, bounded streams, port-forward reconnects, and a 100,000
row synthetic model plus native `NSTableView` harness. Targeted AppKit tests
also pin the resource workspace's accessibility roles, text alternatives, and
the Details/YAML utility presentations.

Swift tests use an in-memory `UserDefaults` store, so they do not create
UUID-named plist files in `~/Library/Preferences`. `make test` also runs a
scoped cleanup trap for any legacy or accidentally created test suites. To
remove leftovers from older test runs, use `make clean-test-preferences`; it
does not touch the application's persistent preference domains.

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
8. Search all keys and multiline values in a ConfigMap and an explicitly
   revealed Secret, stage multiple decoded key changes in each without handling
   base64, inspect every entry in the master-detail review, scroll a long diff
   smoothly with both a trackpad and mouse wheel, and exercise a Data conflict.
   In Details, edit one label and one multiline annotation through their
   separate key/value editors, including Return on the selected Summary row,
   review the staged changes, and verify each save refreshes that exact object's
   Summary. For a restarted Pod, verify Last Restart Reason includes its exit
   code and both relative and absolute finish times.
9. If mutation authorization was given, bulk-delete only approved disposable
   objects in `kmgr-smoke` and verify partial results/UID preconditions.
10. View both Pod and Node metrics, then compare their behavior with Metrics API
    available and unavailable. Verify Nodes show actual usage against their
    object-local allocatable/capacity values, exact huge-page/accelerator
    columns appear after the base snapshot, and opening Nodes starts no Pod
    LIST/WATCH.
11. Press `D` on a selected object and verify its Summary and bounded recent
    Events appear in a utility window while the resource list remains visible.
    Press `Y` to open the object's YAML utility, then `E` to enter editing and
    confirm the validated save flow. From Details, press `E` and confirm a new
    full workspace contains only the UID-pinned object's Events.
12. While a safe resource or detail view is visible, terminate the helper and
    verify the workspace shows a disconnected state, reopens through a fresh
    authenticated session, and does not replay mutations, exec commands, or
    port-forwards.

A real smoke run requires an explicit context name and begins read-only.
Creating/deleting the `kmgr-smoke` namespace or anything inside it requires
separate authorization. Use a disposable cluster and least-privilege
credentials.

## Known limitations

- macOS only; the native UI requires macOS 15 with the current dependency set.
- Kubeconfig exec plugins requiring `interactiveMode: Always` and legacy
  `auth-provider` integrations are deliberately unsupported.
- Supported workloads resolve to a bounded, UID-pinned static Pod snapshot;
  following dynamic workload membership is not implemented.
- Exec reconnect starts a new process; it cannot preserve the original remote
  process.
- Port-forwards and other live sessions are not restored after an app relaunch.
  An unexpected helper restart reopens safe cluster resource/detail views, but
  it does not replay mutations or exec commands; old forwards become failed
  tombstones. Confirmed application quit stops active listeners.
- Metrics Server generally does not provide accelerator, huge-page, or
  ephemeral-storage utilization. Kmgr labels scheduler allocation separately
  and does not manufacture usage.

## Troubleshooting

- **A context is disabled:** inspect the authentication label. Legacy
  `auth-provider` users and exec plugins that always require terminal input are
  rejected intentionally.
- **An exec-auth context does not open:** ensure its command is available from
  a fresh login zsh and can authenticate without terminal input. Credential
  plugins share the connection deadline and are terminated when it expires.
- **Open fails:** the authenticated `/version` probe has a bounded deadline.
  Check the server hostname, VPN/network, credential validity, CA, and
  kubeconfig TLS server-name settings. The failed provisional session is
  closed rather than leaving an apparently connected window.
- **No rows or a reconnecting banner:** keep the cached table visible and read
  the connection/watch state. A stale resource version can cause a background
  relist without blanking usable warm rows. If the current resource remains in
  Resuming or Reconnecting, choose **Resource → Restart Resource Stream**
  (Command-R) to discard its checkpoint and perform a fresh LIST/WATCH. You do
  not need to clear an ordinary search keyword; those filters are evaluated
  locally and are preserved by the restart.
- **Metrics show Unavailable:** grant read access to `metrics.k8s.io` or install
  a compatible Metrics Server. Base LIST/WATCH remains independent.
- **A forward stays Failed after Pod replacement:** this is the UID safety
  contract. Start a new forward explicitly for the replacement Pod.
- **Column configuration fails to load:** verify both version strings and use
  the Settings window to confirm the active path. Invalid files produce an
  explicit configuration error rather than changing CEL meaning silently.
