# kmgr

`kmgr` is a keyboard-first, native macOS Kubernetes manager. The user interface is written with programmatic AppKit and delegates all Kubernetes access to a supervised Go helper process.

The project is under active construction. The current build establishes the native application bundle and helper boundary; cluster workflows are added as buildable vertical slices.

## Requirements

- macOS 15 or later
- Xcode 16.4 or later, including the Swift 6.1 toolchain
- Go 1.24 or later

The macOS 15 deployment target is imposed by the maintained gRPC Swift 2 NIO transport used for authenticated Unix-domain-socket IPC. The app is intended for direct distribution and does not use App Sandbox.

## Developer workflow

```sh
make generate  # regenerate protocol sources
make test      # run Go and Swift tests
make app       # assemble build/Kmgr.app, including kmgr-engine
make run       # build and launch the local app
```

`make app` creates an unsigned local debug bundle. Use `CONFIGURATION=release make app` for an optimized bundle. Release signing, hardened-runtime configuration, and notarization can be applied to the resulting nested-code layout later.

## Architecture

The app has two process boundaries:

- `Kmgr.app` owns windows, responder-chain commands, accessibility, and compact view state.
- `kmgr-engine`, embedded in `Contents/Helpers`, owns kubeconfig handling, Kubernetes clients, watches, caches, projection, mutations, and long-running streams.

Swift Package Manager is the reproducible macOS project definition. `scripts/build-app.sh` builds both executables and assembles the standard application-bundle structure without requiring code signing.

No credentials, Secret values, logs, or terminal contents may be written to application diagnostics.
