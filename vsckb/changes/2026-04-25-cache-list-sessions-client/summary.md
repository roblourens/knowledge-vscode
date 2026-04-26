# Cache listSessions client-side with reconnect invalidation

**Date:** 2026-04-25
**VS Code branch:** roblou/agents/cache-sessions-on-client
**VS Code SHA at finalize:** 99e59eeecd
**PR:** [#312563](https://github.com/microsoft/vscode/pull/312563)

## What was done

`AgentHostSessionListController.refresh()` (workbench side) was calling `connection.listSessions()` on every invocation, even though the controller already maintains an in-memory `_items` / `_cachedSummaries` cache kept in sync by `notify/sessionAdded`, `notify/sessionRemoved`, and `notify/sessionSummaryChanged` AHP notifications. `refresh()` is called by `ChatSessionsService.refreshChatSessionItems` on workspace-folder change, trust change, availability change, items-provider change, and explicit user refreshes — frequently, and far more often than the underlying session list actually changes.

Added a `_cacheValid` flag to `AgentHostSessionListController`: set to `true` after a successful `listSessions()`; subsequent `refresh()` calls skip the RPC and re-emit the cached items; errors leave `_cacheValid` as `false` so the next refresh retries. A `resetCache()` public method was added to allow explicit invalidation.

Because AHP notifications are not replayed on reconnect, the cache must be invalidated when the agent host process restarts (even if the agent registration itself survives). `AgentHostContribution` was updated to track all active `AgentHostSessionListController` instances in a `_listControllers` map and call `resetCache()` on all of them via its existing `onAgentHostStart` listener (which already clears auth caches on restart).

This mirrors the existing one-shot caching in `BaseAgentHostSessionsProvider._ensureSessionCache` on the sessions-app side; the workbench-side controller was the remaining offender.

## Key decisions

- **`_cacheValid` flag rather than a smarter diff:** The controller already holds the authoritative in-memory list via the AHP notification handlers. The cache is "valid" once it's been seeded; the notifications keep it current. No separate diff or TTL is needed.
- **`resetCache()` + `onAgentHostStart` rather than relying solely on controller lifetime:** Controller lifetime handles the connection-replacement case (agent registration tears down, new controller starts with `_cacheValid = false`). But agent host restart without a registration change leaves the same controller alive with a stale `_cacheValid = true`. Explicit reset on `onAgentHostStart` covers that case.
- **`_listControllers` map in `AgentHostContribution`:** Tracked via disposal store so entries are automatically cleaned up when registrations are torn down. Simple `Map<AgentProvider, AgentHostSessionListController>` — one controller per provider.

## What went wrong or was misunderstood

- **Wrong initial assumption about cache invalidation:** The initial design said "cache lifetime is tied to the controller instance; reconnect drops the controller so the cache implicitly resets." This was half-right. Connection *replacement* tears down the registration and a new controller starts fresh. But agent host *restart* (same process slot, same provider, `IAgentHostService.onAgentHostStart` fires) keeps the existing registration and controller alive with `_cacheValid = true`. AHP notifications are not replayed, so the list goes stale permanently. The Copilot code reviewer caught this during PR review. — **prevented by:** the gotcha entry now in `agent-host-session-handler.md#debt--gotchas` documenting both invalidation paths.

## What we learned

- `IAgentHostService.onAgentHostStart` fires on agent host process restart even when the agent registration doesn't change. It is already used for other cache/auth clearing, making it the natural hook for invalidating any cache that depends on agent host state and AHP notification delivery.
- `MockAgentHostService.onAgentHostStart` was `Event.None`, which prevented testing the restart path. It now has a real `Emitter` with a `fireAgentHostStart()` helper — a pattern worth preserving for any future test that exercises restart-sensitive behavior.

## Doc updates

- `docs/agent-host-session-handler.md` — updated "What it does NOT own" bullet for `AgentHostSessionListController` to describe caching and both invalidation paths; added gotcha for AHP-notifications-not-replayed-on-reconnect constraint; added changelog entry.
