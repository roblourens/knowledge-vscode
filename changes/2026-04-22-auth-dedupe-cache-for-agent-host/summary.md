# Auth dedupe cache for agent host

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/client-authentication-issue-exploration
**VS Code SHA at finalize:** 67763f6b5e
**PR:** [#312017](https://github.com/microsoft/vscode/pull/312017)

## What was done

Added a client-side `AgentHostAuthTokenCache` to `agentHostAuth.ts` that prevents redundant `authenticate` RPCs when the Copilot token has not changed. The cache is wired into `AgentHostContribution._authenticateWithServer` (local) and `RemoteAgentHostContribution._authenticateWithConnection` (remote). The server already had a string-equality check that prevented CopilotClient restarts on unchanged tokens, but the RPC was still being sent on every state change — this change stops the call from being made at all.

The fix was prompted by `[Copilot] Auth token unchanged` appearing in logs repeatedly during every agent session: three separate triggers (`rootState.onDidChange`, `onDidChangeSessions`, `onDidChangeDefaultAccount`) were each independently firing `authenticate`, and `rootState.onDidChange` fires on *every* applied protocol action, not just when `protectedResources` changes.

## Key decisions

- **Per-resource granularity.** The cache keys on the protected resource URI so per-resource eviction is possible on RPC failure without invalidating unrelated resources.
- **One cache instance per contribution, not per connection.** For local, the cache lives on `AgentHostContribution`. For remote, it lives on the `ConnectionState` object (dropped when the connection is disposed).
- **Seed after the RPC, not before.** If `authenticate()` throws, `cache.clear(resource)` is called so the failure doesn't suppress the next retry. The initial draft seeded before, which was wrong; caught by Copilot code review.
- **Clear on `onAgentHostStart`.** The local process can restart; its auth state is reset. The cache must be invalidated even when the token value is unchanged from the client's perspective.

## What went wrong or was misunderstood

- **`rootState.onDidChange` fires on every action, not just `protectedResources` changes.** — The event name implies it fires when the state changes value, but it fires on every snapshot, optimistic write, reconcile, and `applyAction`. This is the root cause of the log spam. **Prevented by:** the new gotcha on `agent-host-topology.md` under Debt & gotchas.

- **Cache was initially seeded before the RPC.** — Placing `updateAndIsChanged()` before `await authenticate()` means a transient failure poisons the cache entry and prevents retries. The mistake is non-obvious because in happy-path tests the ordering doesn't matter. **Prevented by:** the new gotcha on `agent-host-topology.md` (`AgentHostAuthTokenCache`) explaining the correct seed-after-success pattern.

- **`onAgentHostStart` clearing was missed in the first pass.** — The agent host process restart scenario wasn't considered until the Copilot code review. **Prevented by:** same gotcha on `agent-host-topology.md` calling out the three cache lifecycle rules together.

- **TypeScript field initialization order caused a runtime error in the test mock.** — `MockAgentHostService.rootState` was declared before `_rootStateOnDidChange`, so `this._rootStateOnDidChange.event` was `undefined` at initialization time. TypeScript does not warn about this class of mistake. **Prevented by:** the new gotcha on `testing.md` about field declaration order in `MockAgentHostService`.

- **Merge conflicts from I-prefixed type names.** — The branch used `IRootState`, `IAgentInfo`, `ICustomizationRef` (anticipating an upcoming rename), but `main` still exports `RootState`, `AgentInfo`, `CustomizationRef`. The rebase produced conflicts in `remoteAgentHost.contribution.ts` and `agentHostChatContribution.test.ts`. Fix: always grep the current exports before assuming a rename has landed.

## What we learned

- The Copilot server's `[Copilot] Auth token unchanged` message is a *server-side* dedupe log, printed even when the RPC makes it all the way to the server. Its presence in logs is normal if client-side dedupe is absent; its *frequency* is the signal — seeing it on every agent turn action is what flags excessive RPCs.
- Copilot code review is effective at catching "cache-before-RPC" style mistakes that are invisible in happy-path tests. Worth wiring `authTokenCache` patterns past review before landing.

## Doc updates

- `docs/agent-host-topology.md` — added "Client-side authentication flow" subsection (three triggers, `AgentHostAuthTokenCache`, cache lifecycle rules); added two gotchas (`onDidChange` fires on every action; cache must be seeded after RPC).
- `docs/testing.md` — added gotcha about TypeScript class field initialization order in `MockAgentHostService`.
