# Performance diagnostics

## Synthetic large-view harness

`KmgrCoreTests` includes a deterministic, AppKit-independent harness for the
compact resource-table model. It progressively installs 100,000 rows, applies
4,000 row updates that produce eight full sort projections, and verifies that
selection and scroll state remain attached to Kubernetes UIDs. It also asserts
that repeated upserts and projections never grow the row map or visible order
beyond the 100,000 live identities.

Run the optimized harness from the repository root:

```sh
swift test --package-path macos -c release --no-parallel --filter LargeViewHarness
```

Print phase timings for local comparisons:

```sh
KMGR_PERF_DIAGNOSTICS=1 \
  swift test --package-path macos -c release --no-parallel --filter LargeViewHarness
```

The normal test has no elapsed-time pass/fail threshold, so shared CI load
cannot make it flaky. An explicit diagnostic gate is available for a modern
Apple Silicon development machine:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel --filter LargeViewHarness
```

That opt-in command uses deliberately generous phase budgets: 15 seconds for
the progressive 100,000-row snapshot, 5 seconds for 4,000 updates/eight reorder
projections, and 2 seconds for identity/cardinality verification. These catch
order-of-magnitude regressions in pure model work; they are not UI frame-time or
cross-machine product guarantees. Record the machine, OS, Swift version, and
load when reporting a budget result.

The GUI bridge separately enforces a 256-message workspace stream buffer. A
deterministic IPC test proves overflow terminates the view with a retryable,
redacted `WorkspaceStreamBufferExceeded` error instead of allowing unbounded
queue growth. This is an enforcement limit, not evidence that 256 queued
messages deliver acceptable UI latency.

## Warm-cache retained-size accounting

The engine's process-memory-only warm resource LRU has simultaneous global and
per-cluster ceilings. The defaults are:

| Scope | Views | Kubernetes objects | Conservative retained bytes |
| --- | ---: | ---: | ---: |
| Process | 24 | 250,000 | 512 MiB |
| Cluster authority | 8 | 100,000 | 192 MiB |

An entry must fit all three ceilings at both scopes. Retained bytes combine an
incrementally maintained, deliberately conservative estimate of immutable
unstructured maps/slices/scalars and UID-store index overhead with the compact
projected row graph retained for immediate stale first paint. They are not live
heap or RSS samples. Raw accounting avoids serializing a whole stopped view
while the lifecycle lock is held, and final-consumer row capture is skipped
when the raw store already fills an individual ceiling. If projected rows push
an otherwise fitting raw entry over either individual byte ceiling, the rows
are discarded and admission is retried raw-only. This ensures a low object
count cannot hide a very large ConfigMap, Secret, or custom resource payload
without letting optional first-paint rows evict the useful raw store outright.

The estimate adds bounded work to the LIST/WATCH insertion path. Exercise that
path independently from fixture construction with:

```sh
go test ./backend/internal/store \
  -run '^$' \
  -bench '^BenchmarkUIDStoreUpsert100K$' \
  -benchtime=1x -benchmem -count=5
```

The benchmark inserts 100,000 prebuilt unstructured Pods and verifies final
cardinality. It has no elapsed-time gate; compare repeated samples and allocation
counts on the same machine when changing retained-size accounting.

`BenchmarkBackendProjection100K/initial_snapshot` also reports
`raw_retained_bytes/op`, `projected_retained_bytes/op`, and their
`warm_candidate_bytes/op` sum after the timed projection. These are
conservative retained-graph estimates for the same object workload, not the
benchmark's allocated `B/op` value. Run it with:

```sh
go test ./backend/internal/view \
  -run '^$' \
  -bench '^BenchmarkBackendProjection100K/initial_snapshot$' \
  -benchtime=1x -benchmem -count=5
```

When diagnostics are enabled, the harness also samples its own process with
Mach `TASK_VM_INFO` before and after the large view. It reports resident size,
physical footprint, and peak physical-footprint growth without including the
SwiftPM driver process. The opt-in budget limits peak physical-footprint growth
to 384 MiB. This is deliberately generous and catches copy-amplification
regressions; one finite run is not a long-duration plateau measurement.

## Synthetic Go projection harness

`backend/internal/view` also has a cluster-independent benchmark for the hot
path that converts immutable Kubernetes objects into compact protobuf rows. It
projects 100,000 synthetic Pods, then applies 4,000 reorder-producing updates
in eight bursts through the real incremental subscription path. The benchmark
checks row cardinality and projection-pass accounting in addition to reporting
time and allocations.

Run one complete workload from the repository root:

```sh
go test ./backend/internal/view \
  -run '^$' \
  -bench '^BenchmarkBackendProjection100K$' \
  -benchtime=1x -benchmem -count=1
```

Standard Go benchmark profiling flags can be added when investigating a
regression:

```sh
KMGR_PROFILE_DIR="$(mktemp -d /tmp/kmgr-view-profile.XXXXXX)"
go test ./backend/internal/view \
  -run '^$' \
  -bench '^BenchmarkBackendProjection100K$' \
  -benchtime=1x -benchmem -count=1 \
  -outputdir "$KMGR_PROFILE_DIR" \
  -cpuprofile cpu.pprof -memprofile mem.pprof
```

The command writes both profiles beneath the displayed temporary directory.
Profiles can contain local process data and should not be committed; inspect
and remove that directory when finished. This benchmark deliberately has no
elapsed-time pass/fail threshold: single-run Go benchmark timings are sensitive
to machine load and profiling overhead. Use repeated unprofiled samples for
timing comparisons and the allocation counts to detect copy amplification.

## Synthetic AppKit table harness

`KmgrAppTests` drives a real view-based `NSTableView` through the same
`ResourceTableAppKitProjection` capture/apply seam used by the workspace. It
installs 100,000 compact rows, projects four selected UIDs, scrolls to a clipped
UID anchor, and performs eight 500-row reorder-producing batches. It verifies
that selection and the pixel scroll offset remain attached to those UIDs and
that AppKit asks for only a viewport-sized number of reusable cells.

Run the Release harness with diagnostics:

```sh
KMGR_PERF_DIAGNOSTICS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter ResourceTableAppKitPerformanceTests
```

An explicit local budget checks that selection, the typical compact-model
reorder, and the typical table reload/scroll restoration fit within one 60 Hz
display frame, with a three-frame ceiling for the slowest of the eight model
applies and synthetic reloads:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter ResourceTableAppKitPerformanceTests
```

These timings isolate AppKit projection after the compact model update. The
harness prints model-apply timing separately and does not classify it as table
reload latency.

## Large structured-value highlighting harness

`SyntaxHighlighterTests` installs synthetic 2 MiB YAML and JSON documents in
factory-created `NSTextView` instances. It verifies that one highlighting
refresh scans only a bounded visible neighborhood, uses temporary layout
attributes, renders whitespace through a visible-range TextKit layout-manager
overlay, and does not place syntax colors or whitespace markers in the text
storage.

The shared `DiffTextDocument` uses the same visible-range overlay for bounded
text portions of YAML and key-value review diffs. Its ranges exclude diff
prefixes, synthetic line separators, headers, notices, and binary/hex rows.

Run the Release diagnostic and opt-in one-frame lexer/apply budget with:

```sh
KMGR_PERF_DIAGNOSTICS=1 KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter SyntaxHighlighterTests
```

The generated YAML uses dense `key: value` lines, while the generated JSON is a
minified array of objects. Both make the bounded range produce many temporary
attribute runs. The timings exclude one-time document installation and initial
styling; they measure a syntax refresh on the main actor.

## Native accessibility contracts

Targeted AppKit tests assert that the workspace resource outline and table
retain native accessibility roles, and that the resource table, filter,
freshness/progress state, and app-wide Port Forwards control expose text
labels. Resource-usage cells separately verify their spoken quantity value and
non-color marker semantics. Focused presentation tests also cover the Details
and YAML utility windows.

These checks catch programmatic accessibility regressions, but they do not
replace a manual VoiceOver navigation/read-order pass in the packaged app.

## Sustained log streaming

The log window retains raw records in a record- and byte-bounded ring with
monotonic in-memory sequence IDs. Once the initial display is built, normal
tailing decodes and formats only records appended since the preceding pass.
Evicted history advances queue heads in both the display cache and virtual
viewport; retained text, line indexes, and unwrapped row geometry are not
rescanned. A filter or display-limit change intentionally performs one bounded
replacement. If the user scrolls away from a live tail, screen projection work
is deferred until they return; raw bounded ingestion continues.

The core regression runs 10,000 append/evict cycles against a full ring and
asserts that every render processes one record. The AppKit regression applies
10,000 edits to an 8,000-chunk viewport and asserts that each edit indexes only
its rebuilt tail. Run both log suites with:

```sh
swift test --package-path macos --no-parallel --filter LogModelsTests
swift test --package-path macos --no-parallel --filter LogWindowControllerTests
```

The status bar increments its cumulative logical `lines tailed` count directly
from each incoming record's line-start marker, without scanning retained or
visible history. It reports transport loss as `records lost before delivery`
and normal local rolling-history pressure as `older records evicted`; these
counts must not be combined.

## Instruments signposts

Release builds contain local `OSSignposter` intervals under subsystem
`cc.chlc.kmgr`. The vocabulary is stable and records only byte/row/column
counts, booleans, stream generations/sequences, filter revisions, and outcome
labels. It never records Kubernetes names, namespaces, UIDs, selectors, filter
text, cell values, log content, credentials, or IPC metadata.

| Category | Interval | Meaning |
| --- | --- | --- |
| `workspace-stream` | `ViewEventDecode` | gRPC protobuf decoding on the stream transport task |
| `resource-table` | `ResourceProjectionRequest` | filter/sort/column request until the progressive snapshot completes, fails, or is superseded |
| `resource-table` | `ResourceModelApply` | one accepted snapshot/delta projected into compact table state on the main actor |
| `resource-table` | `ResourceTableReload` | `NSTableView` reload plus UID-based selection and scroll restoration on the main actor |
| `logs` | `LogStoreAppend` | appending a received batch to the bounded off-main-actor log ring |
| `logs` | `LogTextFormat` | actor-isolated filtering/formatting of the appended record delta, or one bounded replacement after configuration/cursor invalidation |
| `logs` | `LogTextInstall` | virtual viewport prefix eviction/suffix append plus selection/tail restoration on the main actor |

To record interactively:

1. Build a Release app with `CONFIGURATION=release make app` and open
   `build/Kmgr.app`.
2. Open Instruments, choose the **Logging** template (or add **Points of
   Interest** to **Time Profiler**), and attach to **Kmgr**.
3. Filter signposts to subsystem `cc.chlc.kmgr`, then exercise initial list,
   filter/sort changes, bursty watches, and visible/hidden log windows.
4. Correlate `ResourceModelApply`, `ResourceTableReload`, and
   `LogTextInstall` intervals with Main Thread and animation-hitch tracks.

A command-line capture is also possible after the app is running:

```sh
xcrun xctrace record \
  --template 'Logging' \
  --attach Kmgr \
  --time-limit 60s \
  --output kmgr-performance.trace
```

The trace can contain other system/application logs even though Kmgr's
signposts are redacted. Treat it as local diagnostic data and inspect it before
sharing.

For redacted helper RPC timing, launch the app from a terminal with
`KMGR_ENGINE_LOG_LEVEL=debug` as described in the README. The supervisor passes
the validated level to the helper, captures its stderr in the bounded
process-memory diagnostics tail, and tees the same output to the launching
terminal only for this explicit diagnostic mode. The helper logs only RPC
method, duration, and status and never request/response bodies. The engine
diagnostics tail is not persisted to disk or OSLog.

## Go helper profiles

Debug app builds compile an opt-in pprof server behind the `kmgr_dev` Go build
tag. It is disabled unless `KMGR_PPROF_ADDRESS` or the development-only
`--pprof-address` flag names an explicit loopback IP and port. Release app
builds omit both the profiler code and flag; the build-policy test checks the
Release helper dependency graph for that exclusion.

To profile the helper while exercising the native app, build Debug and launch
the executable directly so the child helper inherits the opt-in environment:

```sh
make app
KMGR_PPROF_ADDRESS=127.0.0.1:6060 \
  build/Kmgr.app/Contents/MacOS/Kmgr
```

Then capture a heap or CPU profile locally:

```sh
go tool pprof http://127.0.0.1:6060/debug/pprof/heap
go tool pprof 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'
```

The server rejects wildcard addresses and hostnames, uses an isolated HTTP
handler set, and does not expose `/debug/pprof/cmdline`, because the helper's
launch token is a command-line argument. No Kubernetes names or values are
added as profile labels. Profiles and traces are nevertheless local diagnostic
artifacts from a process that holds cluster clients; inspect them before
sharing and remove them when the investigation is complete.

## Current reference evidence

On 2026-08-14, the diagnostic Release harnesses passed on an Apple M1 Max with
64 GiB RAM, macOS 15.6.1, and Swift 6.1.2. The measured phases were:

| Phase | Time |
| --- | ---: |
| Progressive 100,000-row model snapshot | 4.610 s |
| 4,000 updates across eight reorder batches | 0.602 s |
| Identity and cardinality assertions | 0.020 s |

The complete model case passed in 5.265 seconds. Its in-process physical
footprint grew by 111.5 MiB and its peak physical footprint grew by 125.6 MiB,
to 132.8 MiB. Resident size at the final sample was 289.8 MiB; these metrics
have different accounting rules and should not be conflated.

The Go projection benchmark on the same machine and Go 1.26.5 produced this
one-shot, profile-enabled reference after removing recursive nested-slice
copies from the immutable projection path:

| Backend phase | Time | Bytes/op | Allocations/op |
| --- | ---: | ---: | ---: |
| Initial 100,000-row projection | 231.588 ms | 177,309,272 | 2,861,144 |
| 4,000 updates across eight reorder bursts | 254.485 ms | 8,191,384 | 116,170 |

Against the immediately preceding profiled revision, allocated bytes fell
45.1% for the initial projection and 41.6% for the update bursts; allocation
counts fell 29.5% and 29.2%, respectively. Five unprofiled post-change samples
ranged from 240.257–257.031 ms for the initial projection and
258.096–299.000 ms for the bursts. Only one comparable pre-change timing was
recorded, so the timing values are references rather than evidence of a stable
CPU-speed improvement.

The same machine's one-shot 100,000-object Go fixtures reported these
conservative warm-cache weights:

| Warm candidate component | Retained estimate |
| --- | ---: |
| Raw objects and UID-store indexes | 1,001,726,336 bytes (955.32 MiB) |
| Compact projected rows | 292,827,370 bytes (279.26 MiB) |
| Combined candidate | 1,294,553,706 bytes (1,234.58 MiB) |

All three values come from the same projection workload. Its raw store alone
therefore exceeds both current byte defaults; the separate, lighter
`BenchmarkUIDStoreUpsert100K` fixture reported 367,571,608 bytes (350.54 MiB)
and must not be added to the projection workload's row estimate. These
synthetic results are useful input when tuning defaults; they are not RSS
measurements or evidence that a typical 100,000-object cluster has either
object/column shape.

| AppKit phase/evidence | Result |
| --- | ---: |
| Initial 100,000-row `NSTableView` reload/layout | 2.385 ms |
| Four-UID selection projection | 0.436 ms |
| Typical compact-model apply | 13.562 ms |
| Slowest compact-model apply | 15.792 ms |
| Typical reorder reload/selection/scroll restoration | 0.917 ms |
| Slowest reorder reload/selection/scroll restoration | 1.118 ms |
| Cell-view requests across initial render plus eight reloads | 208 |
| Maximum simultaneously installed table row views | 21 |

The complete AppKit case passed in 0.489 seconds. The slowest compact-model
apply is 75.0% below the preceding 63.138 ms reference after reusing its
UID-index projection during reorder and scroll restoration. These are
single-machine references, not cross-machine or end-to-end product guarantees.

A standalone final Release helper was also held idle for 49.58 seconds with its
local RPC endpoint running and no Kubernetes session open. It consumed 0.00
seconds of user CPU and 0.00 seconds of system CPU; a process sample reported
0.0% CPU. Maximum resident size was 28,737,536 bytes (27.4 MiB), with no swaps
or filesystem I/O reported. This finite, disconnected helper sample is a useful
baseline, but it does not establish authenticated/connected helper idle cost,
GUI idle cost, or a long-duration memory plateau.

## What remains unproven

The AppKit harness proves bounded cell construction and fast programmatic table
projection in isolation. It does not traverse gRPC, run the Go LIST/WATCH
pipeline, contact Kubernetes, or measure input-event-to-screen-paint latency.
The finite Mach samples do not prove a long-duration process-memory plateau or
attribute every allocation/copy. The signposts make real Release UI/IPC phases
measurable but do not by themselves prove an end-to-end latency target.

No recorded trace currently proves one-frame end-to-end selection/navigation
feedback while streams are active, continuous scrolling responsiveness,
end-to-end IPC throughput under a sustained watch, long-duration memory
plateaus, or near-zero GUI and authenticated/connected helper idle CPU.
Metrics-failure isolation is functionally tested but has not been shown to have
"no measurable" base-list effect under a profiler. Hidden log rendering is
suppressed and its storage/output are bounded, but its long-duration memory and
CPU behavior still needs an Instruments recording. Full packaged-app VoiceOver
navigation and read-order testing also remains manual.

For any end-to-end claim, capture Instruments plus Go CPU/heap profiles and
record the app configuration, row/column counts, update rate, machine, OS, and
profiling interval. Do not infer those properties from the model harness alone.
