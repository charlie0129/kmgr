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
swift test --package-path macos -c release --filter LargeViewHarness
```

Print phase timings for local comparisons:

```sh
KMGR_PERF_DIAGNOSTICS=1 \
  swift test --package-path macos -c release --filter LargeViewHarness
```

The normal test has no elapsed-time pass/fail threshold, so shared CI load
cannot make it flaky. An explicit diagnostic gate is available for a modern
Apple Silicon development machine:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --filter LargeViewHarness
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

On 2026-08-13, the diagnostic Release harness passed on an Apple M1 Max with
64 GiB RAM, macOS 15.6.1, and Swift 6.1.2. The measured phases were:

| Phase | Time |
| --- | ---: |
| Progressive 100,000-row model snapshot | 5.591 s |
| 4,000 updates across eight reorder batches | 0.746 s |
| Identity and cardinality assertions | 0.024 s |

The complete Swift Testing case passed in 6.397 seconds. These are a
single-machine reference, not a product performance guarantee.

## What remains unproven

The pure harness does not render an `NSTableView`, traverse gRPC, run the Go
LIST/WATCH pipeline, or contact Kubernetes. Its cardinality assertions do not
measure resident memory, allocations, or copy amplification. The signposts
make real Release UI/IPC phases measurable but do not by themselves prove a
latency target.

No recorded trace currently proves one-frame selection/navigation feedback,
scrolling responsiveness at 100,000 rows, end-to-end IPC throughput under a
sustained watch, process-memory plateaus, or near-zero GUI/helper idle CPU.
Metrics-failure isolation is functionally tested but has not been shown to have
"no measurable" base-list effect under a profiler. Hidden log rendering is
suppressed and its storage/output are bounded, but its long-duration memory and
CPU behavior still needs an Instruments recording.

For any end-to-end claim, capture Instruments plus Go CPU/heap profiles and
record the app configuration, row/column counts, update rate, machine, OS, and
profiling interval. Do not infer those properties from the model harness alone.
