# Release verification

This checklist separates deterministic source and artifact checks from claims
that require a running GUI or a user-authorized Kubernetes context.

## Deterministic gates

Run these from a clean checkout on a supported macOS development host:

```sh
make generate
git diff --exit-code -- gen/go macos/KmgrProto/Generated
make test
make app
./scripts/verify-app.sh
```

`make test` builds the app targets, runs the Go suite, and runs Swift Testing
with in-process parallelism explicitly disabled. The explicit setting is
required for Swift Testing 124.4 even though this SwiftPM version describes
non-parallel execution as its command-line default.

The app verifier does not launch the GUI. It checks the product and bundle
names, identifier, declared and Mach-O minimum macOS version, package type and
principal class; requires exactly one main executable and the `kmgr-engine`
helper; verifies both are executable macOS Mach-O files; performs strict nested
code-signature verification; rejects host/build-tree dynamic-library and search
paths plus an App Sandbox entitlement; and executes only
`kmgr-engine --version`.

Before treating an optimized bundle as a distribution candidate, repeat the
artifact gate in Release configuration:

```sh
CONFIGURATION=release make app
./scripts/verify-app.sh
```

Developer ID signing, hardened runtime, notarization, and stapling belong to a
future distribution pipeline. The local artifact is intentionally ad-hoc
signed.

The synthetic model and native AppKit performance gates are also
cluster-independent:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter LargeViewHarness

KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter ResourceTableAppKitPerformanceTests
```

Together they enforce the documented compact-model budgets,
identity/cardinality invariants, viewport-sized native cell requests, and the
one-frame typical selection/model-apply/table-restoration budgets. They do not
prove end-to-end Kubernetes performance or replace an interactive Instruments
run.

Exercise the backend's matching cluster-independent 100,000-object store and
projection workloads and record allocation counts with:

```sh
go test ./backend/internal/store \
  -run '^$' \
  -bench '^BenchmarkUIDStoreUpsert100K$' \
  -benchtime=1x -benchmem -count=1

go test ./backend/internal/view \
  -run '^$' \
  -bench '^BenchmarkBackendProjection100K$' \
  -benchtime=1x -benchmem -count=1
```

These benchmarks validate UID-store cardinality, retained-size accounting, and
incremental projection behavior but have no elapsed-time gate. Their timings
are machine-load-sensitive; the reference evidence and optional profiling
commands are documented in
`docs/performance.md`.

## Runtime-only evidence

The following completion evidence cannot be produced by the deterministic
gates above:

- Launching the packaged app and visually/accessibility-checking the native
  windows, menus, responders, focus behavior, restoration, and table geometry.
- Exercising real kubeconfig TLS and credentials, API discovery, CRDs, RBAC,
  LIST/WATCH continuity, and Metrics API behavior against an explicitly named
  user-authorized context.
- Interactively validating logs, exec, and resilient port-forwards against real
  Pods and Services.
- Validating YAML, ConfigMap/Secret, scale, restart, metadata, and delete
  mutations. These require separate authorization for disposable objects and
  are not implied by permission to perform read-only checks.
- Recording Instruments and Go CPU/heap profiles for main-thread latency,
  sustained stream throughput, memory plateaus, hidden-window rendering, and
  idle CPU.
- Completing Developer ID signing and Apple notarization for external
  distribution.

The manual cluster workflow and authorization boundary are documented in the
README. Do not infer live-cluster or mutation authorization merely because a
kubeconfig is present on the machine.
