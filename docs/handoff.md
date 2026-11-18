# Project context handoff

ContextWeave captures local sessions and provides one shared MCP service executable for Codex, DeepSeek Harness, Cursor, and Antigravity. It transfers project context into a new agent session. It does not convert native session files or resume another agent's internal execution state.

## Build and connect

Requires macOS 13+, Swift 6, and `zstd` for Harness's default compressed logs (`brew install zstd`). No model API, Node runtime, or remote service is required by ContextWeave.

```sh
./scripts/build-app.sh
./dist/ContextWeave.app/Contents/MacOS/contextweave-mcp --connect
open dist/ContextWeave.app
```

`--connect` adds a marked registration to Codex's `config.toml` and Harness's `cordis.patch.yml`. It preserves other registrations, creates unique backups, reads both files before writing, and refuses an existing unmarked `contextweave` registration. Re-running updates only its own block. If the second write fails, inspect the reported backups before retrying. Keep the helper at the configured path; moving the app requires rerunning `--connect` from its new location. Start a new agent session to load the tools.

The app's **Settings → Agent Access** panel writes, updates, or removes the registrations and also shows the snippets for manual installation. It refuses files containing an unowned or incomplete `contextweave` entry. Each agent launches a separate stdio process that use the same SQLite database; the GUI does not need to stay open. A running helper watches its executable. After that file changes and the current request finishes, it reloads itself on the same standard streams and sends `notifications/tools/list_changed`. Clients that honor the notification refresh the tool list without restarting the agent. The registered path must stay unchanged.

## Use the handoff

First call `memory_list_projects` to discover the project’s stable ID. Default project and session metadata contains no absolute workspace or source-file paths. Legacy absolute workspace paths are still accepted as input for existing integrations. Before leaving Codex, ask it to call:

```json
{
  "name": "memory_log_progress",
  "arguments": {
    "project": "PROJECT-UUID-FROM-LIST",
    "agent": "codex",
    "done": "Implemented the parser; tests pass",
    "next": "Add the session list UI",
    "issues": "None"
  }
}
```

In a new DeepSeek Harness session, ask:

> Call contextweave's memory_get_context with project=PROJECT-UUID-FROM-LIST and target_agent=dsh. Review the handoff, check Git status, then continue the next step.

To return to Codex, log progress with `agent=dsh`, then get context with `target_agent=codex`. Harness exposes these tools as `mcp__contextweave__<tool>`. Call `memory_read_agent` only when the task is to read one agent's original chat. The default handoff is `memory_get_context`.

The context includes recent explicit progress notes and bounded transcript tails, prioritizing the other agent. Workspace and source-file paths are omitted from generated metadata. Session titles, the conversation view, copied handoffs, and MCP session/progress/context results receive best-effort path redaction on output. A bound workspace prefix is replaced with `[PROJECT]` while its project-relative suffix is kept; other detected local absolute paths are replaced with `[LOCAL_PATH]`. Agents should resolve `[PROJECT]` to the selected local workspace and must not guess the hidden path. IDs, ordinary relative paths, common macOS system executables, and common API routes/web URLs are retained. The original source logs and local database keep unredacted content. Redaction is heuristic: uncommon encodings, URLs and ambiguous strings can still contain sensitive data, and paths unrelated to the project lose their location; review content before external sharing. It is a local compilation of source messages, not an AI-generated summary. Agent-reported progress stays separate from source sessions. No other project is substituted when a path is unknown; explicitly bound workspace aliases resolve to the same project. Worktrees with different paths remain separate projects until explicitly bound to the same project ID.

## Tools

- `memory_scan`: refresh capture. Returns counts and up to 20 redacted failure lines. Raw paths are omitted.
- `memory_list_projects`: list known project names and stable project IDs for this device without returning local workspace paths or device IDs. Does not scan.
- `memory_resolve_workspace(path)`: resolve a known local workspace path to its stable project ID without returning the path.
- `memory_list_sessions(project)`: list the latest 200 stored sessions by project ID (or legacy workspace path), without returning source-file paths. Does not scan.
- `memory_bind_workspace(path, project_id, expected_project_id?)`: explicitly attach an absolute path to an existing project. Reassignment requires its current project ID and is refused when that project has other workspace bindings; its sessions and progress move to the target project atomically.
- `memory_get_context(project, target_agent)`: refresh capture and return a bounded handoff (approximately 24,000 characters plus capture counts). This is the default continuation tool.
- `memory_read_agent(project, agent, session_id?, offset?, limit?)`: read one agent's already captured chats. Use it only when asked to read that agent's original chat. Omitting `session_id` opens the latest chat and lists other recent chats. It does not scan. `offset` defaults to 0 and `limit` defaults to 20 (maximum 50).
- `memory_get_session(project, agent, session_id, offset?, limit?)`: page stored messages; default 20, maximum 50 per page. Does not scan.
- `memory_log_progress(project, agent, done, next?, issues?)`: persist an explicit handoff note.

## Storage and capture

Defaults:

- Codex: `~/.codex/sessions/rollout-*.jsonl` (recursive).
- DeepSeek Harness: `~/.dsh/sessions/**/session[.vN].jsonl[.zstd]`.
- Cursor: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` and workspace metadata under `workspaceStorage` (local composer chats).
- Antigravity: `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript[_full].jsonl` and `~/.gemini/antigravity/conversation_summaries.db`.
- SQLite: `~/Library/Application Support/ContextWeave/contextweave.sqlite`.
- Settings: `~/Library/Application Support/ContextWeave/settings.json`.

The Settings window writes the settings file, and both the app and the MCP helper read it, so custom session folders and a custom database apply to both. Explicit settings take precedence over `CODEX_HOME`, `DSH_HOME`, `ANTIGRAVITY_HOME`, and `CONTEXTWEAVE_DB`; the variables still supply defaults when a field is empty. Restart agent sessions after changing paths so their already-running helper processes reopen the new database. `CONTEXTWEAVE_SETTINGS` can point tests or advanced setups at a different settings file. Set explicit environment overrides in each agent's MCP entry when launching from a GUI or a scrubbed environment; all agents and the GUI must point to the same database.

Capture selects the highest numeric Harness log generation and reads concatenated complete Zstandard frames. Incomplete trailing frames/JSON objects are retried after the source changes. Malformed completed JSON lines and decoding failures are returned by `memory_scan` as redacted failure lines. Codex paginated history files share a session ID and global event ordinals: messages are merged by ordinal to prevent older shards overwriting newer history. Subagent fragments, reasoning blocks, and Harness runtime-context user injections are excluded. Tool calls and outputs are retained. Source logs are read only.

The app scans Codex, Harness, Cursor, and Antigravity concurrently, publishes committed sessions while scanning, and loads recent conversation messages first with older pages on demand. It scans at launch, when session files change while watch mode is enabled, and at the configured interval (five minutes by default) while the app is running. `memory_scan` and `memory_get_context` refresh capture. Listing projects or sessions and reading a stored chat use the database and do not scan. Unchanged files are skipped using inode, parser version, size, and modification time. Appends resume from a byte cursor (a compressed-frame cursor for Zstandard) and only the new tail is parsed; a detected rewrite, truncation, inode change, or parser change rereads the file. A rewrite of earlier bytes combined with an append may not be detected by metadata alone. Sessions are stored as summary rows plus one row per message. Full-text search and worktree aliases remain future work. The app currently shows the latest 200 sessions overall.

Original sessions and progress, including their local paths, are stored in plaintext on this computer. Running model extraction or enabling it for a conversation sends redacted user and assistant messages to the configured provider. Receiving agents can also send retrieved context to their own model. Temporary validation databases must not be committed. To disconnect, use **Settings → Agent Access → Remove registration** (backups are kept beside each file), or remove the marked blocks manually / restore the reported backups.

## Validation

`./scripts/swift-local.sh test` covers both parsers, tool results, timestamp precision, history shard merging, repeated capture, append recovery, persistence, strict project scope, bidirectional context, progress, JSON-RPC negotiation/errors, Zstandard concatenation/truncation, and configuration preservation/backups.

Configuration references: [Codex MCP](https://developers.openai.com/codex/mcp), [DeepSeek Harness MCP client](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/mcp/mcp-client/README.md). Implementation was studied from [MemorySQL](https://github.com/Logic647/MemorySQL/tree/7b3360c7d940105e68af7442bda4d84d60d9c97a); ContextWeave uses its own Swift implementation.

### Live handoff validation

A manual Codex–DeepSeek Harness roundtrip verified MCP discovery, retrieval of project-scoped context, recording progress, and retrieval back in Codex. Session identifiers and local validation records are intentionally omitted. A live Cursor session on 2026-11-10 verified project discovery, context retrieval, and progress logging with marker `CW-CURSOR-DSH-20261110-7F2A`. Harness reading that note and writing `CW-DSH-CURSOR-20261110-7F2A` back remains the other half of that roundtrip.

## Cursor handoff and local history

Cursor can use the same MCP server for project context and explicit progress notes. In ContextWeave Settings → Agent Access, choose **Connect Cursor**, or run `dist/ContextWeave.app/Contents/MacOS/contextweave-mcp --connect-cursor`, then restart Cursor and enable the server if prompted. This adds a managed entry to `~/.cursor/mcp.json`, retains other JSON settings and servers, backs up an existing file, and refuses to overwrite an unmanaged `contextweave` entry. Cursor may ask for approval to run MCP tools. See [Cursor MCP setup](https://cursor.com/docs/mcp).

Ask Cursor to call `memory_list_projects`, then `memory_get_context` with the stable project ID and `target_agent=cursor`. Before leaving Cursor, ask it to call `memory_log_progress` with `agent=cursor`, completed work, next steps and blockers. Codex or Harness can then retrieve that note using its own `target_agent`. Call `memory_read_agent` only when the task is to read one agent's original chat. The same path-redaction policy applies to the returned context.

Local Cursor composer sessions are read from its user SQLite database using a consistent read-only snapshot. ContextWeave supports both the inline and chunked conversation-header formats, imports user/assistant text and available tool calls/results, and associates sessions with the local project workspace. The app watches Cursor's global storage, and MCP requests also scan on demand. Unchanged conversations are not rewritten. Cursor's internal database format is undocumented and can change; unsupported records or future formats may require an adapter update. Cursor background-agent chats are remote and are not captured. This transfers context, not a native Cursor session.

## MCP reliability and diagnostics

The stdio server handles requests concurrently with bounded admission. Initialization, tool discovery, and `ping` do not wait for the database or a running scan. Database initialization is lazy: a failed open is reported as a tool error, and a later request can retry after the underlying problem is fixed. Concurrent scans from one helper are coalesced. DeepSeek Harness Zstandard decoding has a 30-second default deadline (`CONTEXTWEAVE_ZSTD_TIMEOUT_SECONDS`, bounded to 1–120 seconds); timeout becomes a capture diagnostic rather than blocking scans forever.

Lifecycle events and fixed error categories are recorded in the macOS unified log under subsystem `local.contextweave.mcp`, category `lifecycle`. These events do not include request arguments, session content, credentials, or paths. For example:

```sh
log show --last 1h --predicate 'subsystem == "local.contextweave.mcp"' --style compact
```

A broken database or denied path cannot be repaired by the server; fix the reported category and retry the tool call. The server cannot restart itself after its host closes the stdio connection: the consuming agent owns process restart and reconnection. Automatic retry of an ambiguous `memory_log_progress` write is not guaranteed safe against duplicates.

To run deterministic stdio fault-injection checks after building the debug helper:

```sh
./scripts/swift-local.sh build --product contextweave-mcp
python3 scripts/test-mcp-resilience.py
```

These checks use temporary files to block a decoder, test ping during scanning, enforce decoder timeouts, reject malformed input, exercise database-startup recovery, and verify atomic helper replacement without changing the production database.

### Memory scopes

Model-extracted candidates start at session scope. The memory page can move an item explicitly to project or global scope; moving it does not change its review status. Only confirmed global and project memories enter project handoffs. Global memories apply across projects, and project memories only to their bound stable project. The latest session's confirmed session memories and generated checkpoint are also included separately; other session memories are available when opening their source conversation. Candidates and excluded items are not included as long-term handoff memory. Source conversation identifiers remain attached when a memory is promoted. Existing confirmed records migrate to project scope; other older records remain session-scoped. This is local behavior, not cross-device synchronization.

### Model memory and task selection

Use the session memory page to run extraction once or enable automatic extraction after app scans. Opt-in applies to that session, endpoint and model. The app processes chronological batches of up to 40 user and assistant messages, using up to 2,000 characters per message. Redaction is best effort. Completed batches persist a checkpoint and cited candidates together. A later scan retries failed automatic jobs after a backoff. Unchanged completed batches reuse their saved result. The review menu can replace a confirmed memory with a candidate of the same kind and scope. The previous item remains in history. Use `memory_get_evidence` with the originating project, agent, session ID and message ID to read the redacted source.

`memory_get_context` accepts an optional `task` for simple lexical ranking, and optional `source_agent` plus `session_id` to select a captured session in the requested project. The pair must be supplied together. This is not semantic search.
