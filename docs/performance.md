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
go test ./backend/internal/view \
  -run '^$' \
  -bench '^BenchmarkBackendProjection100K$' \
  -benchtime=1x -benchmem -count=1 \
  -cpuprofile cpu.pprof -memprofile mem.pprof
```

Profiles can contain local process data and should not be committed. This
benchmark deliberately has no elapsed-time pass/fail threshold: single-run Go
benchmark timings are sensitive to machine load and profiling overhead. Use
repeated unprofiled samples for timing comparisons and the allocation counts
to detect copy amplification.

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

An explicit local budget checks that selection and the typical table
reload/scroll restoration fit within one 60 Hz display frame, with a
three-frame ceiling for the slowest of the eight synthetic reloads:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter ResourceTableAppKitPerformanceTests
```

These timings isolate AppKit projection after the compact model update. The
harness prints model-apply timing separately and does not classify it as table
reload latency.

## Native accessibility contracts

Targeted AppKit tests assert that the workspace resource outline and table
retain native accessibility roles, and that the resource table, filter,
freshness/progress state, and app-wide Port Forwards control expose text
labels. Resource-usage cells separately verify their spoken quantity value and
non-color marker semantics. The Relationships detail test also pins the visible
`potentially incomplete` default and explicit `Scan All Resources…` action.

These checks catch programmatic accessibility regressions, but they do not
replace a manual VoiceOver navigation/read-order pass in the packaged app.

## Instruments signposts

Release builds contain local `OSSignposter` intervals under subsystem
`com.pktium.kmgr`. The vocabulary is stable and records only byte/row/column
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
| `logs` | `LogTextFormat` | detached log filtering/formatting into a bounded string |
| `logs` | `LogTextInstall` | incremental visible `NSTextStorage` prefix eviction/suffix append and selection/tail restoration on the main actor |

To record interactively:

1. Build a Release app with `CONFIGURATION=release make app` and open
   `build/Kmgr.app`.
2. Open Instruments, choose the **Logging** template (or add **Points of
   Interest** to **Time Profiler**), and attach to **Kmgr**.
3. Filter signposts to subsystem `com.pktium.kmgr`, then exercise initial list,
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

For redacted helper RPC timing, run a separately built helper with
`kmgr-engine --log-level debug` as described in the README. The helper logs
only RPC method, duration, and status and never request/response bodies.

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

| AppKit phase/evidence | Result |
| --- | ---: |
| Initial 100,000-row `NSTableView` reload/layout | 2.388 ms |
| Four-UID selection projection | 0.291 ms |
| Typical reorder reload/selection/scroll restoration | 0.990 ms |
| Slowest reorder reload/selection/scroll restoration | 1.110 ms |
| Slowest compact-model apply (reported separately) | 63.138 ms |
| Cell-view requests across initial render plus eight reloads | 208 |
| Maximum simultaneously installed table row views | 21 |

The complete AppKit case passed in 0.863 seconds. These are single-machine
references, not cross-machine or end-to-end product guarantees.

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
plateaus, or near-zero GUI/helper idle CPU.
Metrics-failure isolation is functionally tested but has not been shown to have
"no measurable" base-list effect under a profiler. Hidden log rendering is
suppressed and its storage/output are bounded, but its long-duration memory and
CPU behavior still needs an Instruments recording. Full packaged-app VoiceOver
navigation and read-order testing also remains manual.

For any end-to-end claim, capture Instruments plus Go CPU/heap profiles and
record the app configuration, row/column counts, update rate, machine, OS, and
profiling interval. Do not infer those properties from the model harness alone.
