# Architecture

ContextWeave is a local-first macOS application with a SwiftUI interface and a separate Swift core.

## Current structure

- `Sources/ContextWeaveApp`: application entry point, session browser, Settings window, handoff actions, and localized resources.
- `Sources/ContextWeaveCore`: source parsers, capture orchestration, SQLite storage, project-scoped handoff, and MCP request handling.
- `Sources/ContextWeaveMCP`: standalone stdio MCP executable shared by supported agents.
- `Sources/CSQLite`: system SQLite module.
- `Tests/ContextWeaveCoreTests`: parser, storage, handoff, protocol, and configuration tests.
- `scripts/build-app.sh`: creates a local development app bundle.

## Design direction

- Read source sessions through dedicated adapters and commit data and capture cursors reliably.
- Separate source data, normalized messages, and rebuildable derived indexes.
- Assign stable project identities and explicitly associate workspaces with projects.
- Track memory provenance and confirmation; enforce project scope throughout retrieval.
- Make background tasks recoverable and version their inputs.
- Store timestamps as UTC Unix milliseconds and make external model use configurable.
- Share application services between the interface and MCP integration; validate macOS permissions and background behavior on real systems.
- Keep user-editable paths and capture cadence in a shared JSON settings file that both the app and the MCP helper read; explicit settings take precedence over environment defaults.

Codex, DeepSeek Harness, and local Cursor composer capture, local SQLite storage, session browsing, project-scoped MCP handoff, and a Settings window are implemented; see [handoff](handoff.md). The app and helper share `~/Library/Application Support/ContextWeave/settings.json`, so GUI changes to source folders or the database also apply to newly launched agent sessions. Each scan runs Codex, Harness, and Cursor workers concurrently with independent actor-confined database connections; SQLite WAL, transactions, and a busy timeout coordinate the GUI and MCP processes. The GUI publishes committed sessions during scans and loads conversation messages in pages. Each session is a summary row plus message rows keyed by agent and external ID, with project and activity indexes. Capture cursors commit in the same transaction as new messages, and appends resume from a byte or compressed-frame offset. Multiple explicitly bound local workspaces can reference one project; cross-device synchronization, search, and derived summaries remain future work.


## Storage decision and future synchronization

The local source of truth is SQLite, accessed through the core storage service. All processes use a local database; devices must not open or synchronize the same live SQLite/WAL files over a network or file-sync folder. A future synchronization layer will exchange logical changes between independent device-local databases. Core Data/CloudKit and GRDB are not required by this decision; any Swift wrapper or synchronization transport must preserve the same storage invariants.

- A session is identified within an agent by its external ID. Its messages have source event IDs and ordering; retain source metadata so they can be traced or reprocessed. Capture offsets are device-local implementation details and are committed atomically with messages.
- GUI and MCP processes may scan the same source concurrently. Each scan compares the persisted cursor to the one it parsed inside the write transaction. Codex and Harness retry stale cursors; Cursor discards a stale snapshot and reads it again on a later scan. A stale snapshot never overwrites the winning commit.
- Projects have persistent random UUIDs. A local device has a separately persisted installation UUID and binds canonical workspace paths to project IDs; `(device_id, path)` is unique. Directory names never determine project identity. Schema v4 atomically migrated legacy path-scoped sessions, progress, and workspaces; v5 adds guards against stale path-only writers. Existing `projectID` API properties still hold the legacy workspace path; `stableProjectID` carries the durable project identity.
- Explicit binding can attach another workspace to an existing project. Reassigning a path already bound elsewhere requires the expected previous project ID; it atomically transfers sessions and progress only if the old project has no other workspace bindings. This prevents accidental broad merges, and retains the old project record. Bindings are managed via the core API and `memory_bind_workspace`; no automatic cross-device merging is implemented.
- The device identity file is stored in the settings directory (default `~/Library/Application Support/ContextWeave/.contextweave-device-id`), separately from the database, with a process lock. Preserve it for this installation, but provision a fresh identity on each new device: copying the whole settings directory to a second device clones its identity. Database backups contain project/binding records but should not be used to clone the identity file to other devices.
- Session and message IDs remain keyed by `(agent, external_id)` and `(agent, external_id, message_id)`; before importing sessions from other devices, define and migrate source/device scoping to prevent collisions. The new project IDs alone do not make session synchronization safe.
- Persist explicit progress separately from raw session data. Future sync must define stable operation IDs, versioning, deletion markers, conflict resolution, and provenance before transmitting or merging records. Do not treat file cursors, paths, search indexes, or generated summaries as portable ground truth.
- Schema migrations run inside a transaction and use `PRAGMA user_version`. Older app versions must reject schemas newer than they understand. Database backups must use a SQLite-aware snapshot that includes committed WAL state; copying only the database file while it is open is not a safe backup strategy.
- SQLite FTS and vector indexes, if added, are rebuildable derived data. Validate availability, Chinese search quality, privacy and packaging on supported macOS versions before selecting an implementation.

Current limits: legacy `sessions.project` and `progress.project` still record local paths for compatibility alongside the stable project ID; synchronization, graphical workspace-binding management, migration backup/restore UI, message-level full-text indexing, and conflict resolution are not implemented. A resumed append assumes the source's earlier bytes remain immutable; truncation and inode replacement trigger a reread, but an in-place rewrite combined with an append cannot be detected by the current metadata-only cursor. These are follow-up work, not guarantees of the current model.


The session browser groups workspaces by stable project ID and displays their folder name rather than absolute paths. The default MCP project, session, capture-status and handoff metadata omit local workspace/source paths; MCP tools accept stable project IDs as well as legacy absolute-path inputs. The conversation UI, copied handoff and MCP session/progress/context outputs apply the same best-effort path redactor. `[PROJECT]` preserves the relative suffix of a bound workspace path; `[LOCAL_PATH]` hides other detected local paths. Original database records and source logs remain unchanged. URL contents, ambiguous routes and unusual encodings can still expose sensitive data; absolute paths unrelated to the project cannot be recovered from the redacted output. Local workspace bindings and configured source paths remain on disk and accessible in configuration.
