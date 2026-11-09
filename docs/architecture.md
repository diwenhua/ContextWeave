# Architecture

ContextWeave is a local-first macOS application with a SwiftUI interface and a separate Swift core.

## Current structure

- `Sources/ContextWeaveApp`: application entry point, welcome screen, and localized resources.
- `Sources/ContextWeaveCore`: domain types and future application logic.
- `Tests/ContextWeaveCoreTests`: core tests.
- `scripts/build-app.sh`: creates a local development app bundle.

## Design direction

- Read source sessions through dedicated adapters and commit data and capture cursors reliably.
- Separate source data, normalized messages, and rebuildable derived indexes.
- Assign stable project identities and explicitly associate workspaces with projects.
- Track memory provenance and confirmation; enforce project scope throughout retrieval.
- Make background tasks recoverable and version their inputs.
- Store timestamps as UTC Unix milliseconds and make external model use configurable.
- Share application services between the interface and MCP integration; validate macOS permissions and background behavior on real systems.

The initial product goal is reliable session capture, local storage and project-scoped search, followed by context handoff. These are plans, not implemented features.
