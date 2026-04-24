# Agent Host Sessions Providers

_Covers: src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts, src/vs/sessions/contrib/agentHost/browser/localAgentHostSessionsProvider.ts, src/vs/sessions/contrib/agentHost/browser/agentHostSettings.contribution.ts, src/vs/sessions/contrib/agentHost/browser/agentSessionSettings.contribution.ts, src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHostSessionsProvider.ts, src/vs/sessions/common/agentHostSessionsProvider.ts_

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

## Coexistence with the extension-host provider

When `chat.agentHost.enabled` is `true`, `LocalAgentHostSessionsProvider` coexists with the extension-host `CopilotChatSessionsProvider` — both register with `ISessionsProvidersService` simultaneously. This is safe because each provider filters to its own sessions:

- **Local agent host** — `CopilotAgent.listSessions()` uses a database-existence ownership gate: only SDK sessions with a per-session Agent Host SQLite DB are included (see [copilot-agent-provider § Session Ownership](./copilot-agent-provider.md#session-ownership)).
- **Extension-host CLI** — `CopilotcliSessionService.shouldShowSession()` calls `IChatSessionMetadataStore.getSessionOrigin()`. Sessions without the extension's per-session JSON metadata return `'other'`, which the default filter excludes. Agent-host-created sessions never write this metadata, so they are invisible to the extension.

The suppression gate (`DefaultSessionsProviderContribution` checking `AgentHostEnabledSettingId` and early-returning before registering `CopilotChatSessionsProvider`) was removed — it is no longer needed. Both providers may advertise the same logical session-type id (`copilotcli`); the local provider returns the plain agent label from `_formatSessionTypeLabel` to avoid label conflicts (see the [gotcha below](#debt--gotchas)).

To visually distinguish local-agent-host sessions in the sidebar, workspace labels are formatted as `${folderName} [Local]` via `buildAgentHostSessionWorkspace`'s `providerLabel` parameter, matching the remote provider's `${folderName} [${hostName}]` pattern. The `[Local]` tag appears only on workspace labels, not session-type labels.

## One-shot `_ensureSessionCache` + auth-aware eager load

`BaseAgentHostSessionsProvider._ensureSessionCache()` runs `_refreshSessions()` exactly once, gated by a `_cacheInitialized` flag, and is only invoked from `getSessions()`. After the first call (whether it cached real data or threw / returned nothing) it never retries — subsequent updates have to come from AHP notifications (`notify/sessionAdded`, `notify/sessionRemoved`, `notify/sessionSummaryChanged`).

This caching shape works only if the underlying agent answers `listSessions()` truthfully. If the agent returns an empty list while it can't actually answer yet (e.g. waiting on auth), the provider caches the empty list forever — and the sidebar stays blank until something else (typically the user sending a message → `notify/sessionAdded`) forces a refresh. See [the Copilot agent's authentication contract](./copilot-agent-provider.md#authentication-contract): the agent throws `AHP_AUTH_REQUIRED` rather than lying with `[]`. `_refreshSessions`'s blanket `catch` swallows that throw silently — intentional: we should NOT prompt the user to sign in just to render the sidebar.

The retry trigger is auth-aware eager loading on the renderer side. `LocalAgentHostSessionsProvider`'s constructor registers `autorun(reader => { if (authenticationPending.read(reader)) return; this._cacheInitialized = true; this._refreshSessions(); })`. Because [`authenticationPending` is sticky](../changes/2026-04-17-session-loading-while-authenticating/summary.md) (settles to false exactly once), this fires `_refreshSessions()` precisely once: immediately if auth was already settled (reload case), or as soon as the first auth pass completes (fresh-launch case). The `_cacheInitialized = true` write before the call short-circuits any later `getSessions()` from re-firing.

The remote provider has its own equivalent: `setConnection(...)` explicitly calls `_refreshSessions()` after wiring listeners. Both providers converge on "refresh once we know we can get a real answer" — they just have different "we can get a real answer" signals.

This is the right layer for the fix. The alternative (changing `SessionsManagementService` to call `provider.getSessions()` after subscribing) would push knowledge of this provider's lazy-cache behavior into a generic consumer; agents are free to choose whether `getSessions()` triggers any work, and the provider should be self-sufficient about answering correctly when called.

## Session-type id vs. resource scheme

Two distinct concepts hang off a session type, and they diverged in the [2026-04-20 routing fix](../changes/2026-04-20-remote-agent-session-routing-fix/summary.md):

- **`ISession.sessionType` / `getSessionTypes()[i].id`** — the **logical session type** the new-chat picker uses to identify "which kind of session is this." This is now the agent's `provider` name itself, e.g. `copilotcli`. The same agent shares one logical session-type id across local and remote hosts, so a stale `sessionTypeId` from a previously-active local Copilot session does not blow up new-session creation when the user then picks a remote workspace exposing the same agent. This was the original fix for the misrouting bug.
- **Resource scheme** (the URI scheme on `ISession.resource`) — host-specific routing for the chat-session content provider. Local uses `agent-host-${provider}` (e.g. `agent-host-copilotcli`); remote uses `remoteAgentHostSessionTypeId(connectionAuthority, provider)` (e.g. `remote-ssh__macbook-air-copilotcli`). Computed by the abstract `protected resourceSchemeForProvider(provider)` hook.

The chat-sessions registry (`IChatSessionsService.registerChatSessionContentProvider`) is keyed by the **resource scheme** — `agent-host-copilotcli` for local, `remote-…-copilotcli` for remote. Each `(host × agent)` pair gets its own content provider, model provider, customization sync provider, etc. (See [agent-host-topology](./agent-host-topology.md#the-shared-seam-iagentconnection-and-agenthostsessionhandler).)

Inside the providers, `_syncSessionTypesFromRootState(rootState)` lives on the base and is shared across local and remote. It walks `rootState.agents` and exposes one session type per agent with `id = agent.provider`. There is no longer any alias-map indirection (`WELL_KNOWN_AGENT_SESSION_TYPES`, `_logicalSessionTypeForProvider`, `wellKnownAgentProvider`, `sessionTypeForProvider`, `agentProviderFromSessionType`) — what the agent advertises in `rootState.agents[].provider` is what the picker shows. The local provider previously had a `_getSessionTypesFromContributions()` fallback that derived session types from `IChatSessionsService` contributions when `rootState` hadn't hydrated; that's gone too — sessions types come from one source.



`BaseAgentHostSessionsProvider` (in `agentHost/browser/baseAgentHostSessionsProvider.ts`) is `extends Disposable implements IAgentHostSessionsProvider`. It owns:

- All shared maps and observables: `_sessionCache`, `_pendingSession`, `_currentNewSession*`, `_selectedModelId`, `_newSessionWorkspaces`, `_newSessionConfigs`, `_newSessionAgentProviders`, `_newSessionConfigRequests`, `_runningSessionConfigs`, `_sessionStateSubscriptions`, `_cacheInitialized`.
- All emitters: `_onDidChangeSessions`, `_onDidReplaceSession`, `_onDidChangeSessionConfig`.
- All connection-routed methods (`getSessions`, `getSessionConfig`, `setSessionConfigValue`, `archiveSession`, `sendRequest`, `sendAndCreateChat`, etc.) — they read the connection through `protected abstract get connection(): IAgentConnection | undefined` and skip dispatch (but still update local state) when undefined.
- All AHP notification/action handlers (`_handleSessionAdded`, `_handleConfigChanged`, etc.), wired up through `_attachConnectionListeners(connection, store)`. Local calls this once in the constructor with `this._store`; remote calls it from `setConnection` with a per-connection store so connection replacement disposes everything.
- A single concrete `AgentHostSessionAdapter` (one class, not subclassed) parameterised by an `IAgentHostAdapterOptions` bag: `{ icon, description, loading, buildWorkspace, mapDiffUri? }`.

Subclass hooks the base calls (defaults are local behaviour, remote overrides as needed):

- `protected abstract get connection()` — the live `IAgentConnection` or `undefined`.
- `protected abstract get authenticationPending: IObservable<boolean>` — adapter captures this on construction; remote's is sticky (see below).
- `protected abstract _adapterOptions(): Pick<IAgentHostAdapterOptions, 'description' | 'buildWorkspace'>` — the subclass-specific portion of the adapter options. Base's `createAdapter` (now concrete, not abstract) fills in `icon`, `loading`, and `mapDiffUri` from the corresponding hooks and merges in `_adapterOptions()`. Remote optionally overrides `createAdapter` itself to do extra bookkeeping (it stashes the metadata in `_metaByRawId`) and then delegates to `super.createAdapter()`.
- `protected abstract resourceSchemeForProvider(provider: string): string` — turns an agent provider name into the content-provider resource scheme. Local: `agent-host-${provider}`. Remote: `remoteAgentHostSessionTypeId(connectionAuthority, provider)`.
- `protected abstract _formatSessionTypeLabel(agentLabel: string): string` — formats the human-readable session-type label. The local provider returns the plain agent label (e.g. `Copilot`); the remote provider appends the host name (e.g. `Copilot [my-host]`). The local provider must NOT append `[Local]` because `SessionsManagementService._collectSessionTypes()` deduplicates by `type.id` (first-seen wins), and both the local provider and the extension-host `CopilotChatSessionsProvider` share the `copilotcli` type id — mismatched labels would be non-deterministic in the filter menu.
- `protected abstract resolveWorkspace(...)` — what folder to open with a session.
- `protected abstract id`, `label`, `icon`, `browseActions`.
- Optional overrides: `mapWorkingDirectoryUri`, `mapProjectUri`, `_diffUriMapper`, `onConnectionLost`, `_validateBeforeCreate`, `_noAgentsErrorMessage`, `_notConnectedSendErrorMessage`.

Note: `_syncSessionTypesFromRootState(rootState)` is now **on the base** (was duplicated across providers in different shapes). Both providers call it from their hydration path. See [Session-type id vs. resource scheme](#session-type-id-vs-resource-scheme).

**`update()` returns `boolean`.** Both refresh paths (`_refreshSessions` and the handlers) check the return of `adapter.update(metadata)` and only fire `onDidChangeSessions` when something actually changed. This was previously inconsistent across providers.

## Settings editor file-system providers

Next to the providers themselves, two sibling contributions expose AHP config as synthetic editable JSONC files in the workbench:

- `agentSessionSettings.contribution.ts` + `agentSessionSettingsFileSystemProvider.ts` register the `agent-session-settings://` scheme with `IFileService` and contribute an "Open Session Settings" action under `SessionItemContextMenuId`. Opens a per-session synthetic JSONC document backed by the session's resolved `SessionConfigState` (schema + values). Saves are written back through the provider's `setSessionConfigValue` (mid-session `SessionConfigChanged`).
- `agentHostSettings.contribution.ts` + `agentHostSettingsFileSystemProvider.ts` + `agentHostSettingsShared.ts` register the `agent-host-settings://` scheme and contribute an "Open Host Settings" action. Opens a host-level JSONC document backed by `RootState.config` (the new `RootConfigState`, see [agent-host-protocol](./agent-host-protocol.md)). Saves are written back via the host-level config dispatch path.

Both contributions gate their menu `when` clauses on `ContextKeyExpr.regex(ChatSessionProviderIdContext.key, ANY_AGENT_HOST_PROVIDER_RE)` — the menu only shows for agent-host sessions.

On the **server** side, both per-session and host-level config values now read through `IAgentConfigurationService.getEffectiveValue<D, K>` (`src/vs/platform/agentHost/node/agentConfigurationService.ts`), which owns the `session → parent subagent → host` inheritance chain. Provider-side reads on the renderer still go through the lazy-seeded `_runningSessionConfigs` cache as described below; the new service is what they see *behind* the wire.

## Dynamic session config: the caches

The providers maintain related caches that together drive the session-config picker:

- `_newSessionConfigs: Map<sessionId, IResolveSessionConfigResult>` — for sessions being *created* in the welcome view. The picker writes values into this map as the user fills out the form.
- `_runningSessionConfigs: Map<sessionId, IResolveSessionConfigResult>` — for sessions that are already running. Drives the picker that lives in the chat input toolbar. Values are typed `Record<string, unknown>` (widened from `Record<string, string>` once the protocol started carrying number/boolean/object config values).
- `_sessionStateSubscriptions: DisposableMap<sessionId, IReference<IAgentSubscription<ISessionState>>>` — lazy AHP session-state subscriptions, used to seed `_runningSessionConfigs` on demand.
- Plus host-level `RootConfigState` plumbing on the base for the host-settings editor (see [Settings editor file-system providers](#settings-editor-file-system-providers)).

`getSessionConfig(sessionId)` returns `_newSessionConfigs.get(sessionId) ?? _runningSessionConfigs.get(sessionId)` and synchronously kicks off `_ensureSessionStateSubscription(sessionId)` for the running case. The `??` ordering matters: the new-session form must always win over a stale running entry while the user is creating a session.

The picker side (`agentHostSessionConfigPicker.ts`) renders synchronously and tolerates `undefined` — it relies on `provider.onDidChangeSessionConfig` firing once a value arrives. The well-known `autoApprove` property is dispatched separately to a unified permission picker — see [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md).

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
- **`agentSideEffects.ts` `SessionConfigChanged`** persists `sessionState.config.values` verbatim each time the values change mid-session. Same rationale. The action now also carries an optional `replace?: boolean` — callers distinguish a full-values replacement (settings-editor save) from an incremental merge (single-property picker write); the persistence side stores whatever final shape the reducer produced.

Server-side **reads** (e.g. when an agent asks "what is the current value of `autoApprove` for this session?") flow through `IAgentConfigurationService.getEffectiveValue` (`src/vs/platform/agentHost/node/agentConfigurationService.ts`), which combines per-session values, parent subagent values, and host-level `RootConfigState` values into a single answer. The provider-side renderer cache is still seeded from `ISessionState.config`, but the schema and value resolver now lives in the new service — reach for it (not the old per-call resolver) when adding a new well-known config key.

On restore (`restoreSession`), the agent reads the persisted values out of the database and includes them in the next `ISessionState.config.values` snapshot. Both providers then see them through the lazy seed described above.

This was a previous reviewer suggestion to filter to user-mutable subsets only; we explicitly do **not** do that — see the gotcha entry below.

## Shared helpers

`src/vs/sessions/common/agentHostSessionsProvider.ts` is the shared common module both providers (and the base) import from:

- `IAgentHostSessionsProvider` — the extended `ISessionsProvider` interface.
- `isAgentHostProvider(provider)` — type guard used by callers like `openInVSCode.contribution.ts`.
- `ANY_AGENT_HOST_PROVIDER_RE` — regex matching any agent-host provider id (`/^(local-agent-host|agenthost-)/`). Used by the new settings-editor contributions to gate their menu `when` clauses on `ChatSessionProviderIdContext`.
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
- Integration: `src/vs/platform/agentHost/test/node/protocol/sessionConfig.integrationTest.ts` includes a server-restart test (start two `ScriptedMockAgent` server instances against the same user-data dir; the second one is seeded via `VSCODE_AGENT_HOST_MOCK_SEED_SESSIONS` and verifies the persisted values survive a restart end-to-end).

## Where to edit

- A change that should apply to both providers identically → put it on `BaseAgentHostSessionsProvider` (or the shared adapter) in `agentHost/browser/baseAgentHostSessionsProvider.ts`. Pure types/helpers go into `common/agentHostSessionsProvider.ts`.
- Local-only behaviour → `agentHost/browser/localAgentHostSessionsProvider.ts`.
- Remote-only behaviour (connection lifecycle, sticky auth-pending, well-known agent type mapping, remote folder picker) → `remoteAgentHost/browser/remoteAgentHostSessionsProvider.ts`.
- Picker UI behavior → `src/vs/sessions/contrib/chat/browser/agentHost/agentHostSessionConfigPicker.ts` for the generic per-property picker; `src/vs/sessions/contrib/chat/browser/agentHost/` for the well-known `autoApprove` picker (see [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md)).
- What gets persisted, when, and where the database lives → `src/vs/platform/agentHost/node/agentService.ts` (`createSession` / `restoreSession`) and `src/vs/platform/agentHost/node/agentSideEffects.ts` (`SessionConfigChanged`).
- AHP wire shape (`ISessionState.config`, `SessionConfigPropertySchema`) — see [agent-host-protocol](./agent-host-protocol.md).

## Related

- [agent-host-topology](./agent-host-topology.md) — how the Sessions app relates to the workbench app.
- [agent-host-protocol](./agent-host-protocol.md) — `ISessionState.config`, subscriptions, and the refcounted `getSubscription` model.
- [agent-host-session-handler](./agent-host-session-handler.md) — the other consumer of the same `StateComponents.Session` subscriptions.
- [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) — how the well-known `autoApprove` config property bridges into the unified permission picker.

## Debt & gotchas

- **gotcha** (2026-04-18, agentService.ts:createSession + agentSideEffects.ts:SessionConfigChanged) — we deliberately persist the **full resolved** `sessionConfig.values`, not only the user-mutable subset. Clients render the resolved config on restore and shouldn't have to re-resolve. The persisted values are read back as the source of truth for what the session was actually created with; they are *not* fed back into `resolveSessionConfig` as overrides on restore. Don't "clean this up" by filtering to `sessionMutable: true` — that loses information clients need.
- **gotcha** (2026-04-18, baseAgentHostSessionsProvider.ts:_ensureSessionStateSubscription) — the provider's session-state subscription is refcounted with the Session Handler's. Don't switch to a parallel raw `subscribe` to "keep the picker independent" — that would open a second wire subscription per session. Always go through `connection.getSubscription(...)` so the `IReference` refcount works.
- **gotcha** (2026-04-19, baseAgentHostSessionsProvider.ts:createNewSession) — the draft-state reset block clears **all five** of `_currentNewSession`, `_currentNewSessionStatus`, `_currentNewSessionModelId`, `_currentNewSessionLoading`, `_selectedModelId` together. They're a single conceptual "current draft" tuple; if you add another `_currentNewSession*` field, add it here too. Missing one leaves a half-cleared draft if the function throws before `_createNewSessionForType` runs (e.g. unknown `sessionType`). Caught in code review on PR #311261.
- **gotcha** (2026-04-19, src/vs/sessions/contrib/agentHost/, build/lib/i18n.resources.json) — code under `src/vs/sessions/~` (i.e. `browser/`, `common/`, `node/` directly under `sessions/`) **cannot import from `src/vs/workbench/contrib/*`**. Only code under `src/vs/sessions/contrib/<feature>/~` can. This is enforced by `code-import-patterns` in `eslint.config.js`. The shared `BaseAgentHostSessionsProvider` lives in `sessions/contrib/agentHost/browser/` for exactly this reason — workbench-contrib helpers it depends on are not reachable from `sessions/browser/` or `sessions/common/`. When adding a new contrib folder under `src/vs/sessions/contrib/`, **also add it to `build/lib/i18n.resources.json`** or the hygiene check (`npm run precommit`) fails.
- **gotcha** (2026-04-20, baseAgentHostSessionsProvider.ts:_ensureSessionCache + _refreshSessions, localAgentHostSessionsProvider.ts:authentication autorun) — `_ensureSessionCache` is one-shot via `_cacheInitialized` and only runs from `getSessions()`. If the underlying agent's `listSessions()` returns nothing (or an empty list) on the first call, the cache holds that forever; only AHP notifications (`notify/sessionAdded` etc.) recover it. The local provider's auth-aware autorun in the constructor (gated on `authenticationPending` settling) is what makes eager loading correct — don't remove it without replacing the trigger. The remote provider's equivalent is `setConnection()` calling `_refreshSessions()` directly. The blanket `catch` in `_refreshSessions` is intentional: agents are expected to throw `AHP_AUTH_REQUIRED` while not yet authed (per AHP `required: true`), and we silently wait for the autorun to retry rather than popping a sign-in dialog just to render the sidebar. See `changes/2026-04-20-fix-initial-session-list-display/`.
- **gotcha** (2026-04-20, baseAgentHostSessionsProvider.ts:_syncSessionTypesFromRootState + resourceSchemeForProvider) — `ISession.sessionType.id` is the **agent provider name** (e.g. `'copilotcli'`), NOT the chat-sessions-registry type (e.g. `'agent-host-copilotcli'`). The two diverged deliberately so the same agent has one logical session-type id across hosts. Don't reintroduce alias maps (`WELL_KNOWN_AGENT_SESSION_TYPES`, `_logicalSessionTypeForProvider`, `wellKnownSessionType`/`wellKnownAgentProvider`) — what `rootState.agents[].provider` advertises is exactly what the picker shows. The chat-sessions-registry type lives in the `*Contribution` files, computed as `agent-host-${provider}` (local) or `remoteAgentHostSessionTypeId(authority, provider)` (remote), and is exposed via `resourceSchemeForProvider`.
- **gotcha** (2026-04-20, baseAgentHostSessionsProvider.ts:createAdapter + AgentHostSessionAdapter constructor + protocolServerHandler.ts:listSessions + remoteAgentHostProtocolClient.ts:createSession) — these all `throw` if the AHP session URI has no provider scheme (or, on remote create, if `config.provider` is missing). Do NOT re-add the previous `?? 'copilot'` (or `?? DEFAULT_AGENT_HOST_PROVIDER`, or `?? DEFAULT_AGENT_PROVIDER`) silent fallbacks. Those defaults masked the original misrouting bug — when the client sent the wrong scheme, the server happily wrote `'copilot'` into the metadata anyway. Failing loud is the contract.
- **gotcha** (2026-04-20, baseAgentHostSessionsProvider.ts:_getAgentProviderForSession) — throws if no provider was tracked for a new-session id, rather than returning `'copilot'`. Same rationale as the silent-fallback gotcha above. Anything that creates a `_currentNewSession*` tuple must populate `_newSessionAgentProviders` before any code path can read it back.
- **debt** (2026-04-18, baseAgentHostSessionsProvider.ts:_handleConfigChanged) — `_handleConfigChanged` still has its old `buildMutableConfigSchema(config)` fallback path. Now that lazy seeding works, that branch will normally not fire before the subscription arrives. Worth revisiting whether it can be removed once we're confident no edge case still depends on it.
- **gotcha** (2026-04-21, localAgentHostSessionsProvider.ts:_formatSessionTypeLabel + sessionsManagementService.ts:_collectSessionTypes) — `_collectSessionTypes()` deduplicates session types by `type.id`, keeping the first-seen label. Since both `LocalAgentHostSessionsProvider` and the extension-host `CopilotChatSessionsProvider` share the `copilotcli` type id, the local provider's `_formatSessionTypeLabel` must return the plain agent label (no `[Local]` suffix) — otherwise the filter menu and new-session picker show a non-deterministic label depending on provider registration order.
- **gotcha** (2026-04-22, sessionDatabase.ts:setMetadata) — `setMetadata` writes are sequenced **per key** via `SequencerByKey<string>`. `@vscode/sqlite3` runs in *parallelized* mode by default: two `db.run()` calls on the same connection are dispatched to libuv's thread pool and can complete out of submission order. For "last-writer-wins" keys like `configValues` (written by both `agentService.createSession` and `agentSideEffects.SessionConfigChanged`), unsequenced writes let the older value silently overwrite the newer one on disk. Surfaced as flaky `sessionConfig.integrationTest.ts` failures (PR [#311989](https://github.com/microsoft/vscode/pull/311989)). If you add another `setMetadata` write site, the per-key sequencer already protects you. If you ever change `setMetadata` to bypass it, or add a new "last-writer-wins on a key" write that doesn't go through `setMetadata`, you must add equivalent per-key sequencing — `whenIdle()` is not enough, it waits for completion but doesn't guarantee submission order matches completion order.
- **gotcha** (2026-04-24, remoteAgentHostSessionsProvider.ts:constructor + tunnelAgentHost.contribution.ts:_createProvider) — `RemoteAgentHostSessionsProvider`'s constructor initializes `connectionStatus` to `Disconnected`, and `TunnelAgentHostContribution._createProvider` then calls `setConnectionStatus(Connecting)` *before* `registerProvider()` — both synchronously inside the same call. By the time external code subscribes via `ISessionsProvidersService.onDidChangeProviders`, the `Disconnected → Connecting` (and possibly further) transitions can already have raced past, so a consumer that "watches for `Connecting → Disconnected`" will never observe it. If you need to react to a remote provider failing to connect from outside (e.g. a restored selection's fallback policy), don't rely on observing transitions — combine an `autorun` on `connectionStatus` with a grace-period `disposableTimeout` safety net, and read the *current* status as the source of truth. See `sessionWorkspacePicker.ts:_watchForConnectionFailure` and `changes/2026-04-24-persist-agent-host-workspace-selection/`.

## Changelog

- **2026-04-24** — `99e71fd463` — added gotcha for `RemoteAgentHostSessionsProvider`'s synchronous `Disconnected`-on-construct + `setConnectionStatus(Connecting)` before `registerProvider()` in `tunnelAgentHost.contribution.ts._createProvider`. External subscribers via `onDidChangeProviders` can race past these transitions and never observe them, so connection-failure reactions need a grace-period safety net rather than transition-watching alone (PR [#312037](https://github.com/microsoft/vscode/pull/312037)).
- **2026-04-22** — `08b22f46c1` — added gotcha for `SessionDatabase.setMetadata` per-key sequencing. `@vscode/sqlite3`'s parallelized mode could complete two `db.run()` calls on the same key out of submission order, letting `configValues` writes from `createSession` and `SessionConfigChanged` race; fixed by routing `setMetadata` through `SequencerByKey<string>` (PR [#311989](https://github.com/microsoft/vscode/pull/311989)).
- **2026-04-21** — `7bc767483b` — added "Coexistence with the extension-host provider" section. Removed suppression gate in `copilotChatSessions.contribution.ts`; both providers now register simultaneously. Updated `_formatSessionTypeLabel` doc to reflect plain-label requirement. Added gotcha for session-type label dedup. Local workspace labels now show `[Local]` tag via `buildAgentHostSessionWorkspace` `providerLabel`.
- **2026-04-20** — `7f8e7e0f0c` — added cross-reference to new [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) doc in the picker section, the "Where to edit" line, and the Related section. The `autoApprove` config property is now dispatched out of the generic per-property loop into a unified permission picker shared with the Copilot-CLI flow.

- **2026-04-20** — `d05eca7455` — added "One-shot `_ensureSessionCache` + auth-aware eager load" section covering why the cache is one-shot, how the local provider's `autorun(authenticationPending)` constructor wiring drives the retry, and why the silent catch in `_refreshSessions` is correct. Added matching gotcha. Cross-references the new "Authentication contract" section in `copilot-agent-provider.md`.

- **2026-04-19** — `29c89294e9` — extracted `BaseAgentHostSessionsProvider` and `AgentHostSessionAdapter` to `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts`. Local provider went from full implementation to ~186 LOC subclass; remote went from 1457 LOC to 395 LOC. Local provider also moved into the same `agentHost` contrib folder as the new base (was its own `localAgentHost` contrib). Net ~880 LOC removed. Added gotchas for the layer-rule restriction on `vs/sessions/~` vs `vs/sessions/contrib/*/~`, the `i18n.resources.json` registration requirement, and the `_currentNewSession*` reset tuple. Old `localAgentHostSessionsProvider.ts:` debt/gotcha entries re-anchored to `baseAgentHostSessionsProvider.ts:`.
- **2026-04-18** — `96ab46a042` — initial entry. Captures both Agent Host sessions providers (local + remote), the three-cache config picker model, lazy session-state subscription seeding, the persistence/restore bridge through `AgentService` + `AgentSideEffects`, and the shared `resolvedConfigsEqual` helper. Records the deliberate "persist full resolved values" decision and the refcounted-subscription gotcha.
- **2026-04-21** — `ad531180d0` — reconciliation: fixed stale doc references to the moved session-config integration test and the generic session-config picker path; no covered provider commits since `7bc767483b` changed the provider architecture.
- **2026-04-24** — `5407371c47` — reconciliation: documented two new sibling contributions — `agentSessionSettings.contribution.ts` (per-session `agent-session-settings://` synthetic JSONC editor) and `agentHostSettings.contribution.ts` (host-level `agent-host-settings://` editor for the new `RootConfigState`) — along with the new `IAgentConfigurationService.getEffectiveValue` server-side resolver that owns the session→subagent→host inheritance chain (commits `779b23b6196`, `1453f5b4e9b`, `2289e091159`). Widened `_runningSessionConfigs` value type to `Record<string, unknown>` and noted the new `replace?: boolean` flag on `SessionConfigChanged`. Added `ANY_AGENT_HOST_PROVIDER_RE` to the shared-helpers list. Updated `Covers:` to include the two new contributions.
