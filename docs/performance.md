# Performance diagnostics

`KmgrCoreTests` includes a deterministic large-view harness for the compact
resource-table model. It progressively installs 100,000 rows, applies 4,000
row updates that produce eight full sort projections, and verifies that
selection and scroll state remain attached to Kubernetes UIDs. It also checks
that repeated upserts and projections do not grow the row-map or visible-order
cardinality beyond the 100,000 live identities.

Run only this harness in optimized Release configuration from the repository
root:

```sh
swift test --package-path macos -c release --filter LargeViewHarness
```

Optional phase timings can help compare local changes:

```sh
KMGR_PERF_DIAGNOSTICS=1 swift test --package-path macos -c release --filter LargeViewHarness
```

The timings are diagnostic output only. The test has no elapsed-time pass/fail
threshold, so machine load and CI hardware cannot make it flaky.

## Current reference evidence

On 2026-08-13, the diagnostic Release command above passed on an Apple M1 Max
with 64 GiB RAM, macOS 15.6.1, and Swift 6.1.2. The measured test phases were:

| Phase | Time |
| --- | ---: |
| Progressive 100,000-row model snapshot | 5.591 s |
| 4,000 updates across eight reorder batches | 0.746 s |
| Identity and cardinality assertions | 0.024 s |

The complete Swift Testing case passed in 6.397 seconds. These numbers are a
single-machine reference, not a product performance guarantee or regression
budget.

## What this harness does not prove

The harness exercises pure, AppKit-independent table state. It does not render
an `NSTableView`, traverse gRPC, run the Go LIST/WATCH pipeline, or contact a
Kubernetes API server. Its cardinality assertions do not measure resident
memory, allocations, or copy amplification. It also provides no evidence for
frame latency, scrolling responsiveness, IPC throughput/backpressure, helper
or GUI idle CPU, or sustained process-memory behavior.

Use an end-to-end synthetic stream plus Instruments and Go CPU/heap profiles to
evaluate those properties. Record the app configuration, row/column counts,
update rate, machine, operating system, and profiling interval with any such
claim; do not infer UI or memory performance from this model harness alone.
