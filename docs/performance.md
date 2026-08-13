# Performance diagnostics

`KmgrCoreTests` includes a deterministic large-view harness for the compact
resource-table model. It progressively installs 100,000 rows, applies 4,000
row updates that produce eight full sort projections, and verifies that
selection and scroll state remain attached to Kubernetes UIDs. It also checks
that repeated upserts and projections do not grow the row map or visible order
beyond the 100,000 live identities.

Run only this harness from the Swift package directory:

```sh
cd macos
swift test --filter LargeViewHarness
```

Optional phase timings can help compare local changes:

```sh
KMGR_PERF_DIAGNOSTICS=1 swift test --filter LargeViewHarness
```

The timings are diagnostic output only. The test has no elapsed-time pass/fail
threshold, so machine load and CI hardware cannot make it flaky. This harness
measures the pure AppKit-independent table state, not rendering, IPC, or an
end-to-end Kubernetes LIST/WATCH.
