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
code-signature verification; rejects an App Sandbox entitlement; and executes
only `kmgr-engine --version`.

Before treating an optimized bundle as a distribution candidate, repeat the
artifact gate in Release configuration:

```sh
CONFIGURATION=release make app
./scripts/verify-app.sh
```

Developer ID signing, hardened runtime, notarization, and stapling belong to a
future distribution pipeline. The local artifact is intentionally ad-hoc
signed.

The synthetic model performance gate is also cluster-independent:

```sh
KMGR_PERF_BUDGETS=1 \
  swift test --package-path macos -c release --no-parallel \
  --filter LargeViewHarness
```

It proves the documented model budgets and identity/cardinality invariants; it
does not prove interactive AppKit or end-to-end Kubernetes performance.

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
