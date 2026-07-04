# Share startup session caching across local and remote agent hosts

**Date:** 2026-07-04
**VS Code branch:** roblou/agent-host-session-caching
**VS Code SHA at finalize:** 49de3ac4ac
**PR:** [#324328](https://github.com/microsoft/vscode/pull/324328) (draft) — fixes [#324329](https://github.com/microsoft/vscode/issues/324329); follow-up [#324330](https://github.com/microsoft/vscode/issues/324330)

## What was done

Gave the **local** agent host provider the same "show sessions immediately at startup" behavior the remote provider already had, by **sharing one implementation** instead of duplicating it.

The storage-backed session-summary persistence layer (serialize/deserialize, `_metaByRawId`, `_cacheDirty`, `onWillSaveState`-driven `_persistCache`, `_loadCachedSessions`) lived entirely in `RemoteAgentHostSessionsProvider`. It was hoisted into `BaseAgentHostSessionsProvider` behind an explicit `_enableSessionCachePersistence(storageKey)` opt-in that subclasses call at the end of their constructor, plus a `_shouldTrackSessionCacheChanges()` hook that preserves the remote provider's offline (`unpublishCachedSessions`) gate. The remote provider now just supplies its per-authority key (`remoteAgentHost.cachedSessions.<authority>`); the local provider supplies a fixed key (`localAgentHost.cachedSessions`). Behavior-preserving for remote; net-new startup hydration for local. Scope: agent window only (the editor-window agent-host surface is a separate provider).

A second, more aggressive change (prewarm the agent host process at `BlockRestore` in both windows + reorder `LocalAgentHostContribution` ahead of the heavy `AgentHostContribution`) was prototyped, validated, and then **reverted** to keep the caching PR focused. It is tracked as a follow-up in [#324330](https://github.com/microsoft/vscode/issues/324330).

## Key decisions

- **Hoist into the base rather than duplicate.** Both subclasses (local, remote) are the only two; the machinery is identical modulo the storage key, so the base is the right home.
- **Explicit opt-in, called last in the subclass constructor.** Hydration builds adapters via `createAdapter`, which reads subclass identity fields (`this.id`, `resourceSchemeForProvider`, `_adapterOptions`). The base constructor can't auto-load — hence `_enableSessionCachePersistence(storageKey)` at the end of each subclass ctor.
- **`_shouldTrackSessionCacheChanges()` hook** keeps the remote-only `_unpublished` concept out of the base while preserving offline-snapshot survival.
- **Split into two PRs.** Caching is safe and self-contained; process-prewarm + contribution-reordering touches the workbench lifecycle and warrants separate review. Reverted the prewarm commit (branch was unpushed, so a plain reset — no force-push).
- **Prewarm, not block-phase hydration, for the follow-up.** The process spawn is a cheap non-blocking async trigger (safe at `Ready`); hydration synchronously builds up to 100 observable-heavy adapters, so it should not go on the blocking restore path. Mirrors the extension host's "schedule early, don't block" pattern.

## What went wrong or was misunderstood

- **Assumed the startup lag was "waiting for the agent host to start."** It wasn't — hydration is a synchronous storage read and never awaits the agent host; the lag is *when the provider is constructed* (idle-scheduled at `AfterRestored`, behind the heavy `AgentHostContribution`), while the extension-host copilot list comes from `AgentSessionsModel`'s synchronously-loaded workspace cache. — **prevented by:** new [Startup session cache § latency note](../../docs/agent-host-sessions-providers.md#startup-session-cache-cross-window-persistence) + [agent-host-topology debt entry](../../docs/agent-host-topology.md#debt--gotchas).
- **The doc claimed `_ensureSessionCache` is one-shot and "never retries; only AHP notifications recover it."** The code actually arms a `_scheduleSessionRefreshRetry` backoff (1s→30s) on a thrown `listSessions()`, so a failed initial list self-heals. Re-discovered by reading `_refreshSessions`. — **prevented by:** corrected the "One-shot `_ensureSessionCache`" section body and its gotcha in agent-host-sessions-providers.
- **The persistent session cache existed only in the remote provider with no dedicated doc section** — had to reverse-engineer the whole `_metaByRawId`/`onWillSaveState`/`_persistCache` machinery from the remote source to reuse it. — **prevented by:** new [Startup session cache](../../docs/agent-host-sessions-providers.md#startup-session-cache-cross-window-persistence) doc section.
- **Load-bearing constructor ordering was non-obvious:** calling `_enableSessionCachePersistence` too early builds adapters with the wrong scheme/options. — **prevented by:** new `gotcha` on `baseAgentHostSessionsProvider.ts:_enableSessionCachePersistence`.
- **The agent host process's fully-lazy spawn timing (and how it compares to the extension host) was undocumented** and only surfaced by tracing `_connect` → `AgentHostProcessManager` → `starter.start()`. — **prevented by:** `debt` entry in agent-host-topology + index cross-cutting pointer, referencing #324330.

## What we learned

- **`AgentSessionsModel` (`workbench/contrib/chat/browser/agentSessions/agentSessionsModel.ts`) is a second, independent persistence layer** for agent sessions — a workspace-scoped (`agentSessions.model.cache`) cache loaded synchronously in its constructor. The extension-host `CopilotChatSessionsProvider` reads from it (`agentSessionsService.model.sessions`), which is why copilot sessions can render before the extension activates. The agent-host providers have their own `APPLICATION`-scoped cache instead.
- **`SessionsManagementService` subscribes to `ISessionsProvidersService.onDidChangeProviders` and queries `getSessions()` on registration** — so there is no separate list-construction gate; a provider's sessions paint as soon as it registers with a populated cache. "Hydrate earlier" therefore literally means "register the provider earlier."
- **Extension host startup is the precedent for early process start:** `NativeExtensionService` kicks it off at `lifecycleService.when(LifecyclePhase.Ready).then(runWhenWindowIdle(...))` (comment: can't defer to `Restored` — editors need it, deadlock). The agent host is one phase later and demand-driven.

## Doc updates

- **agent-host-sessions-providers.md** — added the **Startup session cache (cross-window persistence)** section; corrected the "One-shot `_ensureSessionCache`" section (backoff retry, empty-success vs throw); added gotcha for `_enableSessionCachePersistence` end-of-ctor ordering; updated the `sessionAdded`/`_metaByRawId` gotcha (now on the base) and the one-shot-cache gotcha (backoff retry); changelog entry.
- **agent-host-topology.md** — added a `debt` entry for the fully-lazy process spawn timing vs the extension host; changelog entry.
- **index.md** — added a cross-cutting `debt` pointer (agent host spawns lazily/late) under Active debt & gotchas; noted "startup session cache" in the sessions-providers Docs line.
