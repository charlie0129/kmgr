# Project priorities

## Prototype and compatibility

- Kmgr is a prototype. Prefer a clean design and simple logic over backward compatibility.
- Breaking changes and substantial refactors are acceptable when they produce a cleaner result.
- Do not add compatibility shims, migrations, deprecated paths, or legacy fallbacks unless the user explicitly asks for them.
- If persisted configuration is invalid or uses an unsupported format, discard it and reset to defaults. Do not attempt to repair or migrate it.
- Remove dead code related to the task instead of preserving it for hypothetical future use.
- This no-compatibility policy applies to Kmgr's own configuration, internal APIs, and previous app behavior. It does not prohibit compatibility with older Kubernetes API servers.
- Targeted fallbacks for Kubernetes API-server capabilities are acceptable when an older server does not support the preferred API. Prefer API discovery or capability detection over hard-coded Kubernetes version checks, and keep the fallback clean, bounded, and efficient.

## Performance and scale

- Design hot paths for clusters with at least 2,000 Nodes and 50,000 Pods.
- Avoid repeated full-dataset scans, quadratic work, unbounded buffers, unnecessary copies, and per-row work outside the visible viewport. Prefer incremental updates, bounded storage, indexing, batching, and virtualization.
- Do not trade scalability for implementation convenience without discussing it with the user first.
- If the requested behavior cannot be implemented efficiently at the target scale, stop and explain the constraint and alternatives before implementing it.

## Reuse and existing implementations

- Before implementing behavior, you can search the repository and relevant git history for existing implementations, helpers, dependencies, UI patterns, and tests that solve the same or a closely related problem.
- If extending an existing implementation or extracting a clean shared component produces simpler code, prefer it over introducing parallel logic. On the other hand, if it would introduce unnecessary complexity, prefer a separate implementation.

## UX and accessibility

- Prefer keyboard-first workflows. Primary actions should be reachable without a mouse, with predictable focus behavior and native keyboard shortcuts where appropriate.
- Treat dark mode, light mode, accessibility labels, and standard platform behavior as part of the feature rather than optional polish.

## Security trade-offs

- If a secure implementation would add substantial complexity or materially hurt performance, explain the concrete trade-off and ask the user before choosing a weaker design.

## Removing or replacing behavior

- Removal means deletion, not converting the removed implementation into negative assertions.
- Before removing or replacing behavior, inspect the commit or history that introduced it. Use that history to identify the complete cleanup scope.
- Delete obsolete production code, tests, test hooks, identifiers, assets, documentation, generated references, and compatibility paths associated with the removed behavior.
- Delete tests that only covered the removed implementation. Add or update tests only for the new user-visible behavior or an enduring public contract.
- Do not add tests whose purpose is to prove that old implementation details are absent. Do not assert that old strings, identifiers, view types, subviews, files, or hierarchy no longer exist.
- Do not widen access control or add identifiers, APIs, or test hooks solely to verify that removed code is gone. Review the source diff to verify deletion.

## Decisions and user coordination

- Discuss a decision with the user before implementation when different reasonable choices would materially change the UX, data model, architecture, performance, or feature scope.

## Completion and commits

- A feature is complete only after its implementation, directly related cleanup, tests, and documentation are consistent.
- Run verification proportional to the change, including focused tests and the repository's canonical test command when practical.
- Commit completed work. Use the commit message format: `<type>(<scope>): <description>`.
- Do not include unrelated user changes in the commit.
