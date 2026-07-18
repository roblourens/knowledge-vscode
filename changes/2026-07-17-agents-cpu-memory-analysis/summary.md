# Reduce idle Agent Host and extension-host session overhead

**Date:** 2026-07-18
**VS Code branch:** roblou/agents/vscode-agents-cpu-memory-analysis
**VS Code SHA at finalize:** 08a0ee38b2
**PR:** [#326461](https://github.com/microsoft/vscode/pull/326461)

## What was done

A whole-application CPU and memory investigation separated several independent costs in an otherwise idle agent window. TypeScript's VS Code-backed watcher mode created more than ten thousand extension-host watcher registrations and amplified filesystem events; disabling `typescript.tsserver.experimental.useVsCodeWatcher` substantially reduced renderer, extension-host, and file-watcher CPU. The remaining recurring cost came from the extension-host Copilot CLI provider repeatedly enumerating thousands of shared SDK sessions, issuing one filesystem IPC ownership check per session, and reacting to Agent Host JSONL writes with full-list refreshes.

The product change suppresses the extension-host JSONL watcher when Agent Host is enabled and is the default for the current agent or editor window. Agent Host now passes `clientName: 'vscode-agent-host'` on SDK create and resume, allowing the extension to reject those sessions before filesystem work. Legacy sessions use one indexed read of `agentSessionData` instead of one `stat` RPC per SDK session. Producer and consumer tests cover the cross-component marker, surface-specific watcher gates, legacy ownership filtering, one directory read, and zero per-session stats.

## Key decisions

- Gate the JSONL watcher by the effective default for each surface: `chat.agentHost.defaultSessionsProvider` for the agent window and `chat.defaultToCopilotHarness` for editor windows, both requiring `chat.agentHost.enabled`.
- Use SDK `clientName` as an efficient practical routing marker, but keep the Agent Host database as authoritative ownership because `clientName` describes the creating or last-resuming runtime and is mutable.
- Preserve compatibility with old generic client names through one bulk `agentSessionData` directory index rather than abandoning legacy sessions or retaining O(N) IPC.
- Test the producer and consumer sides independently so changing the launcher marker cannot silently leave the extension filter ineffective.

## What went wrong or was misunderstood

- The database-existence coexistence gate was documented without its uncached per-session IPC implementation, so the investigation initially found TypeScript watcher amplification but missed the second independent session-list cost. — **prevented by:** doc body updates in `agent-host-sessions-providers.md` and `copilot-extension-host-cli.md`.
- Lazy row resolution and provider refresh can repeatedly retry deleted worktree repositories, but this negative path was not documented. — **prevented by:** a `debt:` entry in `copilot-extension-host-cli.md`.
- The JSONL monitor's targeted item events were accompanied by global list invalidation, and focus refreshes had no freshness TTL; the existing throttler only coalesced bursts. — **prevented by:** the shared-catalog body section and a `debt:` entry in `copilot-extension-host-cli.md`.

## What we learned

- A renderer-only profile can look quiet while extension-host IPC, file watching, Git subprocesses, and utility processes consume substantial CPU; whole-application traces are required for this class of investigation.
- A `file:` URI does not imply local in-process I/O inside an extension: `IFileSystemService` can still cross the extension-host/workbench boundary.
- Disabling the VS Code-backed TypeScript watcher removes extension-host watcher fan-out, but moves legacy watching back into tsserver processes; process-wide memory should still be evaluated separately.
- Shared SDK metadata is useful for fast routing, but a durable ownership decision needs a persistence-layer fallback.

## Doc updates

- Updated `docs/copilot-extension-host-cli.md` with shared SDK-catalog ownership, watcher gating, and two new debt entries for refresh amplification and stale-worktree retries.
- Updated `docs/agent-host-sessions-providers.md` with the current coexistence contract; no debt/gotcha entry was added there.
- Updated `docs/copilot-agent-provider.md` with the launcher client marker and database-authority distinction; no debt/gotcha entry was added there.
- Updated `index.md` descriptions and added cross-cutting pointers for both remaining debt items.
