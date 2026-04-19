# Agent Host Sessions Providers

_Covers: src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts, src/vs/sessions/contrib/agentHost/browser/localAgentHostSessionsProvider.ts, src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHostSessionsProvider.ts, src/vs/sessions/common/agentHostSessionsProvider.ts_

`LocalAgentHostSessionsProvider` and `RemoteAgentHostSessionsProvider` are the Sessions app's view of Agent Host sessions. Both extend a shared abstract base, `BaseAgentHostSessionsProvider`, that owns ~all of the structural behaviour: the session cache, the three config caches, the lazy `ISessionState.config` subscription seeding, AHP notification/action handlers, `sendAndCreateChat`, and a single concrete `AgentHostSessionAdapter` (`ISession` implementation). The subclasses contribute only the bits that genuinely differ: which connection to use, how to label sessions, how to map session types ↔ resource schemes, how to pick a working folder, and (remote only) connection lifecycle. Both implement `IAgentHostSessionsProvider` (defined in `src/vs/sessions/common/agentHostSessionsProvider.ts`), which extends `ISessionsProvider` with the Agent Host extras the Sessions UI needs: dynamic session config, optional remote connection status, and an output channel id. The local provider talks to `IAgentHostService` (utility-process MessagePort); the remote provider talks to an `IRemoteAgentHostConnection` over WebSocket / SSH / tunnel relay.

For where this layer sits in the broader topology, see [agent-host-topology](./agent-host-topology.md). For the AHP wire model these providers consume, see [agent-host-protocol](./agent-host-protocol.md). Turn execution and chat rendering happen elsewhere — see [agent-host-session-handler](./agent-host-session-handler.md).

## Responsibilities

For each provider:

- **List sessions.** Calls `connection.listSessions()`, maps to `ISession` for the Sessions app, and maintains an in-memory `_sessionCache` keyed by raw session id.
- **Open / activate sessions.** Translates a Sessions-app session id (chat-session-style id) ↔ canonical AHP `AgentSession.uri(provider, rawId)`.
- **Surface dynamic session config.** Resolves the per-agent config schema for new sessions and exposes per-session config values to the picker UI.
- **Persist session config across windows.** Cooperates with `AgentService` and `AgentSideEffects` so a session opened from the cached list — possibly in a fresh window — sees the same picker values it had on the server.
- **Bridge connection status.** Remote provider exposes `connectionStatus` and `remoteAddress`; local provider has neither.

The providers do **not** own turn dispatch, file edits, terminals, permissions, or model selection — those are the [Session Handler](./agent-host-session-handler.md)'s job. The split is clean: **providers serve list and picker; handler runs turns**.

## Base / subclass split

`BaseAgentHostSessionsProvider` (in `agentHost/browser/baseAgentHostSessionsProvider.ts`) is `extends Disposable implements IAgentHostSessionsProvider`. It owns:

- All shared maps and observables: `_sessionCache`, `_pendingSession`, `_currentNewSession*`, `_selectedModelId`, `_newSessionWorkspaces`, `_newSessionConfigs`, `_newSessionAgentProviders`, `_newSessionConfigRequests`, `_runningSessionConfigs`, `_sessionStateSubscriptions`, `_cacheInitialized`.
- All emitters: `_onDidChangeSessions`, `_onDidReplaceSession`, `_onDidChangeSessionConfig`.
- All connection-routed methods (`getSessions`, `getSessionConfig`, `setSessionConfigValue`, `archiveSession`, `sendRequest`, `sendAndCreateChat`, etc.) — they read the connection through `protected abstract get connection(): IAgentConnection | undefined` and skip dispatch (but still update local state) when undefined.
- All AHP notification/action handlers (`_handleSessionAdded`, `_handleConfigChanged`, etc.), wired up through `_attachConnectionListeners(connection, store)`. Local calls this once in the constructor with `this._store`; remote calls it from `setConnection` with a per-connection store so connection replacement disposes everything.
- A single concrete `AgentHostSessionAdapter` (one class, not subclassed) parameterised by an `IAgentHostAdapterOptions` bag: `{ icon, description, loading, buildWorkspace, mapDiffUri? }`.

Subclass hooks the base calls (defaults are local behaviour, remote overrides as needed):

- `protected abstract get connection()` — the live `IAgentConnection` or `undefined`.
- `protected abstract get authenticationPending: IObservable<boolean>` — adapter captures this on construction; remote's is sticky (see below).
- `protected abstract createAdapter(metadata): AgentHostSessionAdapter` — builds the adapter with subclass-specific icon/description/workspace.
- `protected abstract resourceSchemeForSessionType(...)`, `agentProviderFromSessionType(...)` — session-id ↔ scheme mapping.
- `protected abstract resolveWorkspace(...)` — what folder to open with a session.
- `protected abstract id`, `label`, `icon`, `browseActions`.
- Optional overrides: `mapWorkingDirectoryUri`, `mapProjectUri`, `_diffUriMapper`, `onConnectionLost`, `_validateBeforeCreate`, `_noAgentsErrorMessage`, `_notConnectedSendErrorMessage`.

**`update()` returns `boolean`.** Both refresh paths (`_refreshSessions` and the handlers) check the return of `adapter.update(metadata)` and only fire `onDidChangeSessions` when something actually changed. This was previously inconsistent across providers.

## Dynamic session config: the three caches

The providers maintain three related caches that together drive the session-config picker:

- `_newSessionConfigs: Map<sessionId, IResolveSessionConfigResult>` — for sessions being *created* in the welcome view. The picker writes values into this map as the user fills out the form.
- `_runningSessionConfigs: Map<sessionId, IResolveSessionConfigResult>` — for sessions that are already running. Drives the picker that lives in the chat input toolbar.
- `_sessionStateSubscriptions: DisposableMap<sessionId, IReference<IAgentSubscription<ISessionState>>>` — lazy AHP session-state subscriptions, used to seed `_runningSessionConfigs` on demand.

`getSessionConfig(sessionId)` returns `_newSessionConfigs.get(sessionId) ?? _runningSessionConfigs.get(sessionId)` and synchronously kicks off `_ensureSessionStateSubscription(sessionId)` for the running case. The `??` ordering matters: the new-session form must always win over a stale running entry while the user is creating a session.

The picker side (`agentHostSessionConfigPicker.ts`) renders synchronously and tolerates `undefined` — it relies on `provider.onDidChangeSessionConfig` firing once a value arrives.

## Lazy seeding from `ISessionState.config`

Sessions opened from the cached list are not created in this window, so neither `_runningSessionConfigs` nor any incoming `SessionConfigChanged` action fires for them. The fix is the **lazy session-state subscription**: on first `getSessionConfig(sessionId)` for a known cached session that has no entry, the provider acquires `connection.getSubscription(StateComponents.Session, sessionUri)` (refcounted via `IReference`), seeds `_runningSessionConfigs` from `state.config` once it hydrates, and listens for subsequent `onDidChange` to keep its cache in sync.

Key invariants:

- **Refcounted subscription.** Both `IAgentHostService.getSubscription` and the remote `IAgentConnection.getSubscription` are refcounted. The Session Handler also holds the same wire subscription for any session whose chat content is loaded — the provider's seeding does not open a second wire subscription, it joins the existing one. Disposal of the provider's `IReference` is what releases the refcount; releasing the last one tears the wire subscription down.
- **Resolved-equality short-circuit.** `_seedRunningConfigFromState` compares the new candidate to the existing entry via `resolvedConfigsEqual` (exported from `src/vs/sessions/common/agentHostSessionsProvider.ts`). If structurally equal, it no-ops — this avoids spurious `onDidChangeSessionConfig` fires from re-seeds. Both providers import the helper from the shared module.
- **Lifecycle.** Local provider disposes the per-session subscription in `_handleSessionRemoved`. Remote provider stores the map under `_connectionListeners` so a connection replacement disposes every per-session subscription alongside the rest of the connection state.
- **Synchronous return contract preserved.** `getSessionConfig` still returns `undefined` on the first call for an unseeded session and lets the picker re-render when the seed arrives. The upstream picker `autorun` already handles that.

## Persistence: the bridge between AgentService and providers

Lazy seeding from `ISessionState.config` would be enough on its own *if the server always rehydrated the full config schema and values on resume*. It doesn't always do that — config like `autoApprove` is stored per-window, and the agent side may have no record of what the user picked when the session was created. To paper over this, `AgentService` persists session config into the per-session Agent Host database, and the providers read it back through the normal session-state subscription path (the agent side reads it, includes it in `state.config.values`, the providers see it via the seed).

Two write sites in `src/vs/platform/agentHost/node/`:

- **`agentService.ts` `createSession`** persists the **full resolved values** (`sessionConfig.values`) on session create. The "full resolved values" choice is deliberate: clients render the resolved config on restore and shouldn't have to re-resolve it. The persisted values are read back as the source of truth for what the session was *actually created with*. They are **not** fed back into `resolveSessionConfig` as overrides on restore — restore returns them as-is.
- **`agentSideEffects.ts` `SessionConfigChanged`** persists `sessionState.config.values` verbatim each time the values change mid-session. Same rationale.

On restore (`restoreSession`), the agent reads the persisted values out of the database and includes them in the next `ISessionState.config.values` snapshot. Both providers then see them through the lazy seed described above.

This was a previous reviewer suggestion to filter to user-mutable subsets only; we explicitly do **not** do that — see the gotcha entry below.

## Shared helpers

`src/vs/sessions/common/agentHostSessionsProvider.ts` is the shared common module both providers (and the base) import from:

- `IAgentHostSessionsProvider` — the extended `ISessionsProvider` interface.
- `isAgentHostProvider(provider)` — type guard used by callers like `openInVSCode.contribution.ts`.
- `resolvedConfigsEqual(a, b)` — shallow structural equality on `IResolveSessionConfigResult`. Compares value keys + values, then schema property keys. Schema property objects are compared by identity (they originate from the same protocol snapshot in the providers that use this helper).
- `buildMutableConfigSchema(config)` — fallback schema-builder used by the (legacy) `_handleConfigChanged` path before lazy seeding hydrates.
- `AUTO_APPROVE_ENUM` — shared enum used by both providers' picker config schemas.

When adding logic that has to be identical between local and remote, prefer extending the abstract base in `agentHost/browser/baseAgentHostSessionsProvider.ts` over duplicating in both subclasses. Pure types/helpers with no DOM/workbench dependencies still go into `common/agentHostSessionsProvider.ts`.

## Tests

- `src/vs/sessions/contrib/agentHost/test/browser/localAgentHostSessionsProvider.test.ts` and `src/vs/sessions/contrib/remoteAgentHost/test/browser/remoteAgentHostSessionsProvider.test.ts` exercise:
  - Listing, session add/remove, status mapping.
  - Lazy session-state subscription seeding (`SessionAdded` → `getSessionConfig` initially `undefined`, then populated after the fake state hydrates; structural-equality short-circuit; per-session subscription disposed on remove; remote case also asserts that replacing the connection disposes all per-session subscriptions).
- `src/vs/platform/agentHost/test/node/agentService.test.ts` covers the persistence side (`createSession` writes values; `restoreSession` after dropping in-memory state restores them).
- `src/vs/platform/agentHost/test/node/agentSideEffects.test.ts` covers mid-session persistence on `SessionConfigChanged`.
- Integration: `src/vs/platform/agentHost/test/node/sessionConfig.integrationTest.ts` includes a server-restart test (start two `ScriptedMockAgent` server instances against the same user-data dir; the second one is seeded via `VSCODE_AGENT_HOST_MOCK_SEED_SESSIONS` and verifies the persisted values survive a restart end-to-end).

## Where to edit

- A change that should apply to both providers identically → put it on `BaseAgentHostSessionsProvider` (or the shared adapter) in `agentHost/browser/baseAgentHostSessionsProvider.ts`. Pure types/helpers go into `common/agentHostSessionsProvider.ts`.
- Local-only behaviour → `agentHost/browser/localAgentHostSessionsProvider.ts`.
- Remote-only behaviour (connection lifecycle, sticky auth-pending, well-known agent type mapping, remote folder picker) → `remoteAgentHost/browser/remoteAgentHostSessionsProvider.ts`.
- Picker UI behavior → `src/vs/sessions/contrib/chat/browser/agentHostSessionConfigPicker.ts`.
- What gets persisted, when, and where the database lives → `src/vs/platform/agentHost/node/agentService.ts` (`createSession` / `restoreSession`) and `src/vs/platform/agentHost/node/agentSideEffects.ts` (`SessionConfigChanged`).
- AHP wire shape (`ISessionState.config`, `ISessionConfigPropertySchema`) → see [agent-host-protocol](./agent-host-protocol.md).

## Related

- [agent-host-topology](./agent-host-topology.md) — how the Sessions app relates to the workbench app.
- [agent-host-protocol](./agent-host-protocol.md) — `ISessionState.config`, subscriptions, and the refcounted `getSubscription` model.
- [agent-host-session-handler](./agent-host-session-handler.md) — the other consumer of the same `StateComponents.Session` subscriptions.

## Debt & gotchas

- **gotcha** (2026-04-18, agentService.ts:createSession + agentSideEffects.ts:SessionConfigChanged) — we deliberately persist the **full resolved** `sessionConfig.values`, not only the user-mutable subset. Clients render the resolved config on restore and shouldn't have to re-resolve. The persisted values are read back as the source of truth for what the session was actually created with; they are *not* fed back into `resolveSessionConfig` as overrides on restore. Don't "clean this up" by filtering to `sessionMutable: true` — that loses information clients need.
- **gotcha** (2026-04-18, baseAgentHostSessionsProvider.ts:_ensureSessionStateSubscription) — the provider's session-state subscription is refcounted with the Session Handler's. Don't switch to a parallel raw `subscribe` to "keep the picker independent" — that would open a second wire subscription per session. Always go through `connection.getSubscription(...)` so the `IReference` refcount works.
- **gotcha** (2026-04-19, baseAgentHostSessionsProvider.ts:createNewSession) — the draft-state reset block clears **all five** of `_currentNewSession`, `_currentNewSessionStatus`, `_currentNewSessionModelId`, `_currentNewSessionLoading`, `_selectedModelId` together. They're a single conceptual "current draft" tuple; if you add another `_currentNewSession*` field, add it here too. Missing one leaves a half-cleared draft if the function throws before `_createNewSessionForType` runs (e.g. unknown `sessionType`). Caught in code review on PR #311261.
- **gotcha** (2026-04-19, src/vs/sessions/contrib/agentHost/, build/lib/i18n.resources.json) — code under `src/vs/sessions/~` (i.e. `browser/`, `common/`, `node/` directly under `sessions/`) **cannot import from `src/vs/workbench/contrib/*`**. Only code under `src/vs/sessions/contrib/<feature>/~` can. This is enforced by `code-import-patterns` in `eslint.config.js`. The shared `BaseAgentHostSessionsProvider` lives in `sessions/contrib/agentHost/browser/` for exactly this reason — workbench-contrib helpers it depends on are not reachable from `sessions/browser/` or `sessions/common/`. When adding a new contrib folder under `src/vs/sessions/contrib/`, **also add it to `build/lib/i18n.resources.json`** or the hygiene check (`npm run precommit`) fails.
- **debt** (2026-04-18, baseAgentHostSessionsProvider.ts:_handleConfigChanged) — `_handleConfigChanged` still has its old `buildMutableConfigSchema(config)` fallback path. Now that lazy seeding works, that branch will normally not fire before the subscription arrives. Worth revisiting whether it can be removed once we're confident no edge case still depends on it.

## Changelog

- **2026-04-19** — `29c89294e9` — extracted `BaseAgentHostSessionsProvider` and `AgentHostSessionAdapter` to `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts`. Local provider went from full implementation to ~186 LOC subclass; remote went from 1457 LOC to 395 LOC. Local provider also moved into the same `agentHost` contrib folder as the new base (was its own `localAgentHost` contrib). Net ~880 LOC removed. Added gotchas for the layer-rule restriction on `vs/sessions/~` vs `vs/sessions/contrib/*/~`, the `i18n.resources.json` registration requirement, and the `_currentNewSession*` reset tuple. Old `localAgentHostSessionsProvider.ts:` debt/gotcha entries re-anchored to `baseAgentHostSessionsProvider.ts:`.
- **2026-04-18** — `96ab46a042` — initial entry. Captures both Agent Host sessions providers (local + remote), the three-cache config picker model, lazy session-state subscription seeding, the persistence/restore bridge through `AgentService` + `AgentSideEffects`, and the shared `resolvedConfigsEqual` helper. Records the deliberate "persist full resolved values" decision and the refcounted-subscription gotcha.
