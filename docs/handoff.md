# Project context handoff

ContextWeave captures local sessions and provides one shared MCP service executable for Codex, DeepSeek Harness, and Cursor. It transfers project context into a new agent session. It does not convert native session files or resume another agent's internal execution state.

## Build and connect

Requires macOS 13+, Swift 6, and `zstd` for Harness's default compressed logs (`brew install zstd`). No model API, Node runtime, or remote service is required by ContextWeave.

```sh
./scripts/build-app.sh
./dist/ContextWeave.app/Contents/MacOS/contextweave-mcp --connect
open dist/ContextWeave.app
```

`--connect` adds a marked registration to Codex's `config.toml` and Harness's `cordis.patch.yml`. It preserves other registrations, creates unique backups, reads both files before writing, and refuses an existing unmarked `contextweave` registration. Re-running updates only its own block. If the second write fails, inspect the reported backups before retrying. Keep the helper at the configured path; moving the app requires rerunning `--connect` from its new location. Start a new agent session to load the tools.

The app's **Settings → Agent Access** panel writes, updates, or removes the registrations and also shows the snippets for manual installation. It refuses files containing an unowned or incomplete `contextweave` entry. Each agent launches a separate stdio process that use the same SQLite database; the GUI does not need to stay open.

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

To return to Codex, log progress with `agent=dsh`, then get context with `target_agent=codex`. Harness exposes these tools as `mcp__contextweave__<tool>`.

The context includes recent explicit progress notes and bounded transcript tails, prioritizing the other agent. Workspace and source-file paths are omitted from generated metadata. Session titles, the conversation view, copied handoffs, and MCP session/progress/context results receive best-effort path redaction on output. A bound workspace prefix is replaced with `[PROJECT]` while its project-relative suffix is kept; other detected local absolute paths are replaced with `[LOCAL_PATH]`. Agents should resolve `[PROJECT]` to the selected local workspace and must not guess the hidden path. IDs, ordinary relative paths, common macOS system executables, and common API routes/web URLs are retained. The original source logs and local database keep unredacted content. Redaction is heuristic: uncommon encodings, URLs and ambiguous strings can still contain sensitive data, and paths unrelated to the project lose their location; review content before external sharing. It is a local compilation of source messages, not an AI-generated summary. Agent-reported progress stays separate from source sessions. No other project is substituted when a path is unknown; explicitly bound workspace aliases resolve to the same project. Worktrees with different paths remain separate projects until explicitly bound to the same project ID.

## Tools

- `memory_scan`: scan changed source files and report failures.
- `memory_list_projects`: discover project names and stable project IDs for this device without returning local workspace paths or device IDs.
- `memory_resolve_workspace(path)`: resolve a known local workspace path to its stable project ID without returning the path.
- `memory_list_sessions(project)`: list the latest 200 sessions by project ID (or legacy workspace path), without returning source-file paths.
- `memory_bind_workspace(path, project_id, expected_project_id?)`: explicitly attach an absolute path to an existing project. Reassignment requires its current project ID and is refused when that project has other workspace bindings; its sessions and progress move to the target project atomically.
- `memory_get_context(project, target_agent)`: refresh capture and return a bounded handoff (approximately 24,000 characters plus capture diagnostics).
- `memory_get_session(project, agent, session_id, offset?, limit?)`: page source messages; default 20, maximum 50 per page.
- `memory_log_progress(project, agent, done, next?, issues?)`: persist an explicit handoff note.

## Storage and capture

Defaults:

- Codex: `~/.codex/sessions/rollout-*.jsonl` (recursive).
- DeepSeek Harness: `~/.dsh/sessions/**/session[.vN].jsonl[.zstd]`.
- Cursor: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` and workspace metadata under `workspaceStorage` (local composer chats).
- SQLite: `~/Library/Application Support/ContextWeave/contextweave.sqlite`.
- Settings: `~/Library/Application Support/ContextWeave/settings.json`.

The Settings window writes the settings file, and both the app and the MCP helper read it, so custom session folders and a custom database apply to both. Explicit settings take precedence over `CODEX_HOME`, `DSH_HOME`, and `CONTEXTWEAVE_DB`; the variables still supply defaults when a field is empty. Restart agent sessions after changing paths so their already-running helper processes reopen the new database. `CONTEXTWEAVE_SETTINGS` can point tests or advanced setups at a different settings file. Set explicit environment overrides in each agent's MCP entry when launching from a GUI or a scrubbed environment; all agents and the GUI must point to the same database.

Capture selects the highest numeric Harness log generation and reads concatenated complete Zstandard frames. Incomplete trailing frames/JSON objects are retried after the source changes. Malformed completed JSON lines and decoding failures are visible in diagnostics. Codex paginated history files share a session ID and global event ordinals: messages are merged by ordinal to prevent older shards overwriting newer history. Subagent fragments, reasoning blocks, and Harness runtime-context user injections are excluded. Tool calls and outputs are retained. Source logs are read only.

The app scans Codex, Harness, and Cursor concurrently, publishes committed sessions while scanning, and loads recent conversation messages first with older pages on demand. It scans at launch, when session files change while watch mode is enabled, and at the configured interval (five minutes by default) while the app is running. MCP context and list calls refresh on demand. Unchanged files are skipped using inode, parser version, size, and modification time. Appends resume from a byte cursor (a compressed-frame cursor for Zstandard) and only the new tail is parsed; a detected rewrite, truncation, inode change, or parser change rereads the file. A rewrite of earlier bytes combined with an append may not be detected by metadata alone. Sessions are stored as summary rows plus one row per message. Full-text search, automatic semantic summaries, and worktree aliases remain future work. The app currently shows the latest 200 sessions overall.

Original sessions and progress, including their local paths, are stored in plaintext on this computer. No source content is sent to a model by ContextWeave itself; the receiving agent can send retrieved context to its configured model. Temporary validation databases must not be committed. To disconnect, use **Settings → Agent Access → Remove registration** (backups are kept beside each file), or remove the marked blocks manually / restore the reported backups.

## Validation

`./scripts/swift-local.sh test` covers both parsers, tool results, timestamp precision, history shard merging, repeated capture, append recovery, persistence, strict project scope, bidirectional context, progress, JSON-RPC negotiation/errors, Zstandard concatenation/truncation, and configuration preservation/backups.

Configuration references: [Codex MCP](https://developers.openai.com/codex/mcp), [DeepSeek Harness MCP client](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/mcp/mcp-client/README.md). Implementation was studied from [MemorySQL](https://github.com/Logic647/MemorySQL/tree/7b3360c7d940105e68af7442bda4d84d60d9c97a); ContextWeave uses its own Swift implementation.

### Live handoff validation

A manual Codex–DeepSeek Harness roundtrip verified MCP discovery, retrieval of project-scoped context, recording progress, and retrieval back in Codex. Session identifiers and local validation records are intentionally omitted. Cursor's local capture and MCP integration are covered by automated and fixture-based checks; a live Cursor Agent roundtrip remains to be verified.

## Cursor handoff and local history

Cursor can use the same MCP server for project context and explicit progress notes. In ContextWeave Settings → Agent Access, choose **Connect Cursor**, or run `dist/ContextWeave.app/Contents/MacOS/contextweave-mcp --connect-cursor`, then restart Cursor and enable the server if prompted. This adds a managed entry to `~/.cursor/mcp.json`, retains other JSON settings and servers, backs up an existing file, and refuses to overwrite an unmanaged `contextweave` entry. Cursor may ask for approval to run MCP tools. See [Cursor MCP setup](https://cursor.com/docs/mcp).

Ask Cursor to call `memory_list_projects`, then `memory_get_context` with the stable project ID and `target_agent=cursor`. Before leaving Cursor, ask it to call `memory_log_progress` with `agent=cursor`, completed work, next steps and blockers. Codex or Harness can then retrieve that note using its own `target_agent`. The same path-redaction policy applies to the returned context.

Local Cursor composer sessions are read from its user SQLite database using a consistent read-only snapshot. ContextWeave supports both the inline and chunked conversation-header formats, imports user/assistant text and available tool calls/results, and associates sessions with the local project workspace. The app watches Cursor's global storage, and MCP requests also scan on demand. Unchanged conversations are not rewritten. Cursor's internal database format is undocumented and can change; unsupported records or future formats may require an adapter update. Cursor background-agent chats are remote and are not captured. This transfers context, not a native Cursor session.
