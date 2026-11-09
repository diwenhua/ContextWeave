# ContextWeave

ContextWeave is a local-first macOS app for carrying project context across AI agents. It uses SwiftUI and a separate Swift core.

[简体中文](docs/README.zh-CN.md)

## Status

Early development: the app currently contains a welcome screen and basic session types. Session capture, storage, search, and handoff are planned.

## Development

Open `Package.swift` in Xcode to browse, build, run, and test the package. Select the `ContextWeave` scheme to run the app.

Requires macOS 13 or later and Swift 6. Full Xcode is recommended for XCTest and debugging.

```sh
./scripts/swift-local.sh build
./scripts/swift-local.sh test
./scripts/swift-local.sh run ContextWeave
```

Build and open a local development app:

```sh
./scripts/build-app.sh
open dist/ContextWeave.app
```

The app bundle is unsigned and intended for local development. Distribution requires signing and notarization. On affected Command Line Tools installations, `swift-local.sh` works around stale Swift Package interfaces using a temporary project-local copy. XCTest requires a working Xcode installation.

The interface follows macOS language preferences, with English as the development language and Simplified Chinese available. See [architecture](docs/architecture.md), [contributing](CONTRIBUTING.md), and [releasing](docs/releasing.md). Licensed under [MIT](LICENSE).
