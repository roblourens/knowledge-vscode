# Reduce duplication between local and remote Agent Host sessions providers

**Date:** 2026-04-19
**VS Code branch:** agents/reduce-duplication-agent-providers
**VS Code SHA at finalize:** 29c89294e9
**PR:** https://github.com/microsoft/vscode/pull/311261 (draft)

## What was done

Extracted the structural overlap between `LocalAgentHostSessionsProvider` and `RemoteAgentHostSessionsProvider` into a new abstract base, `BaseAgentHostSessionsProvider`, plus a single concrete `AgentHostSessionAdapter` (parameterised by an options bag rather than subclassed). Lives at `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts` (1158 LOC).

The base owns: the session cache, all three config caches (`_newSessionConfigs`, `_runningSessionConfigs`, `_sessionStateSubscriptions`), all `_currentNewSession*` draft state, the AHP notification/action handlers, `sendAndCreateChat`, and the lazy session-state subscription seeding. Subclasses contribute only what genuinely differs: which `IAgentConnection` to use (`protected abstract get connection()`), how to label sessions, session-type ↔ resource-scheme mapping, working-folder picker, and (remote only) connection lifecycle.

Both subclasses became thin: `LocalAgentHostSessionsProvider` ~186 LOC, `RemoteAgentHostSessionsProvider` ~395 LOC (was 1457). Net ~880 LOC removed across the affected files.

As part of the same change, the user asked to consolidate the local provider into the same `agentHost` contrib folder as the new base — there's no longer a separate `localAgentHost` contrib. Remote stays in its own `remoteAgentHost` contrib because its connection lifecycle is meaningfully more complicated.

## Key decisions

- **Single concrete adapter, not an abstract one.** `AgentHostSessionAdapter` takes an `IAgentHostAdapterOptions = { icon, description, loading, buildWorkspace, mapDiffUri? }`. No subclassing of the adapter — keeps the per-instance differences declarative and avoids a parallel base/sub hierarchy on the adapter side.
- **Connection abstraction as `IAgentConnection | undefined`.** Local always returns the always-present `IAgentHostService`; remote returns its possibly-undefined `_connection`. Base methods route through this single getter and skip wire dispatch (but still update local state) when undefined.
- **Connection-lifecycle hook: `_attachConnectionListeners(connection, store)`.** Local calls it once in the constructor with `this._store`. Remote calls it from `setConnection` with a per-connection `DisposableStore` so connection replacement disposes every per-session subscription alongside the rest of the connection state.
- **`update()` returns `boolean`.** Both refresh paths now check `didChange` and only fire `onDidChangeSessions` when something actually changed. Previously this was inconsistent across providers.
- **Sticky `authenticationPending` stays remote-only.** Once first auth pass settles, never surface pending again. Implemented via an `_authenticationSettled` flag in the remote `setAuthenticationPending`.
- **Local moved into `sessions/contrib/agentHost/`; remote stays in `sessions/contrib/remoteAgentHost/`.** Three contribs would have been over-fragmented; remote is significantly more complex than local (connection lifecycle, well-known agent type mapping, output channel) and earns its own folder.

## What went wrong or was misunderstood

- **Layer rule for `vs/sessions/` was misjudged twice.** Initially put the base in `src/vs/sessions/common/agentHostSessionsProvider.ts` (couldn't, common can't import workbench/contrib). Pivoted to `src/vs/sessions/browser/baseAgentHostSessionsProvider.ts` — also wrong, hit by ESLint hygiene: `vs/sessions/~` (i.e. `browser/`, `common/`, `node/` directly under `sessions/`) cannot import `vs/workbench/contrib/*`. Only code under `vs/sessions/contrib/<feature>/~` can. Final home: `src/vs/sessions/contrib/agentHost/browser/`. — **prevented by:** new gotcha on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md) + a cross-cutting pointer in [index.md](../../index.md).
- **`build/lib/i18n.resources.json` registration is required for new contrib folders.** Hit a hygiene failure on the first commit because the new `vs/sessions/contrib/agentHost` entry was missing. — **prevented by:** baked into the same gotcha on the sessions-providers doc and called out in the cross-cutting index entry.
- **Missed one `_currentNewSession*` field in the draft-state reset.** `createNewSession` resets `_currentNewSession`, `_selectedModelId`, `_currentNewSessionModelId`, `_currentNewSessionLoading` but I initially forgot `_currentNewSessionStatus`. If `sessionType` lookup or `_validateBeforeCreate` throws after the resets, the previous draft's status observable would dangle. Caught by Copilot review on the PR. — **prevented by:** new gotcha on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md) telling future authors to treat the five fields as a single conceptual draft tuple.
- **Hygiene formatter has no CLI binary.** The pre-commit `npm run precommit` validates formatting but doesn't auto-fix; `build/lib/formatter.ts` is the only entry point. Had to write a tiny `--experimental-strip-types` Node wrapper to format manually. — **prevented by:** noted here in the change summary; not material enough to belong on a doc, but worth recording so the next person hitting it spends less time looking for a flag that doesn't exist.

## What we learned

- The plan from `plan` was structurally accurate — the abstraction split it described (base + options-bag adapter + connection getter + listener-attach hook) was the right one and survived contact with the code unchanged. The only adjustment was the file location, driven by the layer rule.
- The `_currentNewSession*` field group is tightly coupled state that reads as separate observables but behaves as a single draft tuple. The reset bug was a direct consequence of that conceptual gap not being made explicit in the code or docs. The new gotcha addresses this for future additions.
- Worktree state surprises (empty `out/`, missing `node_modules` symlinks, a `.knowledge` symlink replaced by a real directory between `implement` and `finalize`) suggest the session-worktree tooling has rough edges. Not a knowledge-base concern; raised here only as an observation.

## Doc updates

- Updated [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md): rewrote intro, added "Base / subclass split" section, refreshed `Covers:`, file paths in "Tests" and "Where to edit", and the shared-helpers section to mention `buildMutableConfigSchema` + `AUTO_APPROVE_ENUM`. Re-anchored existing `gotcha`/`debt` entries from `localAgentHostSessionsProvider.ts:` to `baseAgentHostSessionsProvider.ts:`. Added two new gotchas: `_currentNewSession*` reset tuple and the `vs/sessions/` layer rule + i18n.resources.json requirement. Appended a `2026-04-19 — 29c89294e9` changelog entry.
- Updated [index.md](../../index.md): refreshed the one-liner and `Covers:` for the sessions-providers doc; added a cross-cutting pointer under `## Active debt & gotchas` for the `vs/sessions/` layer rule.
