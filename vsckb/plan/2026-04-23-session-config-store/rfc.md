# RFC: Deepen agent host session-config plumbing into `IAgentHostSessionConfigStore`

_Status: design proposal — not implemented._
_Origin: `improve-codebase-architecture` exploration session, 2026-04-23._

## Problem

The "what is the resolved AHP config for session X right now, and how does it survive a window reload?" concept is fragmented across at least three layers and ten+ named pieces of state. Today, answering it requires reading:

- Three caches on `BaseAgentHostSessionsProvider`
  ([baseAgentHostSessionsProvider.ts](../../../vscode/src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts)):
  - `_newSessionConfigs` (untitled-phase drafts)
  - `_runningSessionConfigs` (committed-phase, drives the running picker)
  - `_sessionStateSubscriptions` (lazy refcounted `IReference<IAgentSubscription<SessionState>>`)
- Five satellite maps on the same class: `_newSessionWorkspaces`, `_newSessionAgentProviders`, `_newSessionConfigRequests`, `_sessionCache`, `_pendingSession`.
- Two seed paths writing into `_runningSessionConfigs`: `_seedRunningConfigFromState` (full schema, from AHP `SessionState.config`) and `_handleConfigChanged` (incremental, with the `buildMutableConfigSchema` fallback).
- The transition method `_preserveNewSessionConfig(oldId, newId)` that carries `_newSessionConfigs → _runningSessionConfigs` on session commit.
- The optimistic-write-then-dispatch pattern inside `setSessionConfigValue` / `replaceSessionConfig`, which also handles raw-id translation, `ActionType.SessionConfigChanged` envelope construction, and `sessionMutable`/`readOnly` enforcement.
- Wire-side persistence in `agentService.ts` (`createSession`) and `agentSideEffects.ts` (`SessionConfigChanged`) — necessary context for understanding why the renderer's caches behave the way they do.
- Helpers in [agentHostSessionsProvider.ts](../../../vscode/src/vs/sessions/common/agentHostSessionsProvider.ts) (`resolvedConfigsEqual`, `buildMutableConfigSchema`).

The knowledge doc for this area
([agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md)) has two consecutive sections (`Lazy seeding from ISessionState.config`, `Persistence: the bridge between AgentService and providers`) that exist solely to explain *why* these pieces have to know about each other — that's the clearest "this concept wants to be one module" signal in the area.

Why this matters:

- **Integration risk in the seams.** Bugs here are silent: a stale cache shows wrong picker values; a missing seed leaves the picker blank forever; a re-seed without the equality short-circuit causes UI churn. Pure unit tests on each cache miss exactly these wiring bugs.
- **Hard to navigate (human or AI).** The three-cache state machine is reconstructed in the reader's head every time someone touches the area.
- **Hard to test at the right level.** Today's tests have to drive the whole `BaseAgentHostSessionsProvider` (1259 LOC) just to assert on the cache state transitions.

## Proposed interface

A per-provider `IAgentHostSessionConfigStore` that owns all dynamic-config state and exposes per-session handles for the hot path (pickers, JSONC editor) plus admin methods for the owning provider's lifecycle and wire-notification handlers.

```ts
// src/vs/sessions/common/agentHostSessionConfigStore.ts (new)

export interface ISessionConfigHandle {
    readonly sessionId: string;

    /**
     * Reactive snapshot. `undefined` means "not yet seeded" — render an
     * empty state and wait for the observable to tick.
     *
     * Reading triggers a lazy `IAgentConnection.getSubscription` on first
     * read for a running session; the refcount is shared with any handler
     * subscription and released on `forgetRunning` / store dispose.
     */
    readonly current: IObservable<ResolveSessionConfigResult | undefined>;

    /**
     * Set one property. Optimistic local update; wire dispatch in the
     * background. For untitled sessions: re-resolves the schema. For
     * running sessions: silently no-ops if the property is not
     * `sessionMutable`, `current` isn't seeded, or the connection is
     * gone. Best-effort — does not throw.
     */
    set(property: string, value: unknown): Promise<void>;

    /**
     * Atomically replace user-editable values. Carries non-mutable /
     * `readOnly` properties through unchanged. Drops unknown keys.
     * No-op for untitled sessions and for replaces structurally equal
     * to current values.
     */
    replace(values: Record<string, unknown>): Promise<void>;

    /** Dynamic completions for one property; honors auth-pending gate. */
    completions(property: string, query?: string): Promise<readonly SessionConfigValueItem[]>;
}

export interface IAgentHostSessionConfigStore extends IDisposable {
    // ---- Hot path (pickers + JSONC editor) -------------------------------

    /** Get / intern the handle for `sessionId`. Cheap, sync, stable identity. */
    for(sessionId: string): ISessionConfigHandle;

    // ---- Lifecycle (BaseAgentHostSessionsProvider only) ------------------

    /** Open an untitled-phase entry; triggers initial `resolveSessionConfig`. */
    beginUntitled(sessionId: string, agentProvider: string, workingDirectory: URI): void;

    /** Carry untitled → running, preserving full schema + values. */
    commitUntitled(untitledSessionId: string, runningSessionId: string): void;

    /** Drop an abandoned untitled draft. */
    abandonUntitled(sessionId: string): void;

    /** Drop a running entry (called from SessionRemoved handler). */
    forgetRunning(sessionId: string): void;

    /** Snapshot of values to pass to `createSession`. `undefined` outside untitled phase. */
    pendingCreateValues(sessionId: string): Record<string, unknown> | undefined;

    // ---- Wire ingest (BaseAgentHostSessionsProvider only) ----------------

    /**
     * Apply an inbound AHP `SessionConfigChanged` action. Reconciles against
     * optimistic local state; `resolvedConfigsEqual` short-circuits no-op
     * echoes of our own dispatch. Uses `buildMutableConfigSchema` fallback
     * when no schema is cached yet.
     */
    ingestWireChange(sessionId: string, config: Record<string, unknown>, replace: boolean): void;
}

export interface ISessionConfigStoreHost {
    readonly connection: IObservable<IAgentConnection | undefined>;
    readonly authenticationPending: IObservable<boolean>;
    resolveWireRoute(sessionId: string): { rawId: string; agentProvider: string } | undefined;
}
```

`IAgentHostSessionsProvider` collapses its seven config methods into one field:

```ts
export interface IAgentHostSessionsProvider extends ISessionsProvider {
    readonly connectionStatus?: IObservable<RemoteAgentHostConnectionStatus>;
    readonly remoteAddress?: string;
    outputChannelId?: string;
    connect?(): Promise<void>;
    disconnect?(): Promise<void>;

    /** Per-provider session config. Pickers go through `sessionConfig.for(id)`. */
    readonly sessionConfig: IAgentHostSessionConfigStore;
}
```

### Usage at the call sites

```ts
// agentHostSessionConfigPicker._renderConfigPickers (sync render)
const cfg = provider.sessionConfig.for(session.sessionId).current.read(reader);
if (!cfg) { return; }
for (const [property, schema] of Object.entries(cfg.schema.properties)) { … }

// agentHostSessionConfigPicker._showPicker → onSelect
provider.sessionConfig.for(sessionId).set(property, item.value).catch(noop);

// AgentHostPermissionPickerDelegate.setPermissionLevel
provider.sessionConfig.for(session.sessionId)
    .set(SessionConfigKey.AutoApprove, level)
    .catch(noop);

// AgentSessionSettingsFileSystemProvider.writeFile
await provider.sessionConfig.for(sessionId).replace(parsedValues);
```

## Dependency strategy

**In-process** for the store; **local-substitutable** for the wire (a fake `IAgentConnection` against the existing in-memory transport stand-in is sufficient).

- The store is constructed by `BaseAgentHostSessionsProvider` via `IInstantiationService.createInstance` and registered as a disposable.
- Connection comes in as `IObservable<IAgentConnection | undefined>` so the store reacts to swap-on-reconnect: it disposes its `getSubscription` refs when the observable transitions to `undefined`, and re-acquires lazily on the next `current` read against the new connection. The in-memory cache survives across the swap so the picker stays populated while the wire is detached.
- Auth-pending comes in as `IObservable<boolean>` — `set` / `replace` / `completions` short-circuit while it's true. Per-session `loading` continues to live on `ISession`, unchanged.
- `resolveWireRoute(sessionId)` is the one back-edge to the provider — the store needs `(rawId, agentProvider)` for outbound `SessionConfigChanged` dispatch and for constructing `AgentSession.uri` for `getSubscription`. This is the only place the store sees the provider's session-cache shape.
- No DI decorator on the store itself — it's per-provider, not a singleton.

## Testing strategy

**New boundary tests to write:**

- **Untitled → committed → seeded from state.** Begin untitled, the picker reads `current` (empty) → `set('autoApprove', 'autopilot')` → store re-resolves and emits → commit → wire `SessionState.config` arrives via the lazy seed → equality short-circuit fires (no event), then a real change updates the handle.
- **Re-seed equality short-circuit.** Two identical `SessionState.config` snapshots delivered in sequence must produce exactly one observable tick.
- **`replace` policy.** Caller passes values for a `readOnly` property, a `sessionMutable: false` property, an unknown property, and a real mutable property. Wire dispatch must contain only the real mutable change; non-mutable values must be carried through; structurally-equal replace must not dispatch.
- **Reconnect.** Connection observable transitions `A → undefined → B`. Per-session subscriptions opened against `A` are disposed at the `→ undefined`; the next `current` read re-acquires against `B`. Cached values stay populated across the gap.
- **Optimistic write.** `set` updates `current` synchronously; the wire echo arriving with the same values produces no extra observable tick (equality short-circuit).
- **Auth gate.** While `authenticationPending` is true, `set`/`replace`/`completions` are no-ops; flushing auth doesn't replay queued writes (matches current behavior — document this).
- **Wire ingest with no cached schema.** `ingestWireChange` arrives for a session with no prior entry; store synthesizes a minimal schema via `buildMutableConfigSchema` and emits.

**Old tests to delete (or rewrite as boundary tests against the store):**

- Any test in `localAgentHostSessionsProvider.test.ts` / `remoteAgentHostSessionsProvider.test.ts` that asserts on `_newSessionConfigs` / `_runningSessionConfigs` state directly — these become redundant once boundary tests cover the contract.
- `_seedRunningConfigFromState` / `_preserveNewSessionConfig` private-method tests, if any.

**Test environment needs:** a fake `IAgentConnection` with an `IObservable`-backed `getSubscription`. The existing in-memory transport infrastructure used elsewhere in the agent host suite covers this.

## Implementation recommendations

Durable architectural guidance, not coupled to today's file paths:

- **The store owns the entire dynamic-config state machine for one provider.** All cache entries, request counters, lazy subscription handles, and optimistic-write bookkeeping live behind its API. The owning provider must not maintain any parallel cache.
- **The store does not own persistence.** The agent side (over the wire) is the source of truth for "what config did this session have when it was created"; the store's caches are a renderer-side projection of `SessionState.config` plus optimistic local edits. The persistence-via-`AgentService.createSession` / `agentSideEffects.SessionConfigChanged` mechanism is unchanged.
- **The store hides untitled vs running from picker callers.** Lifecycle methods are admin-only and called from one place (the owning provider). `for(id)` accepts both phases of id transparently.
- **The store hides wire-envelope construction.** Picker callers never see `ActionType.SessionConfigChanged`, never see `AgentSession.uri(provider, rawId)`, never see the `replace` flag.
- **The store enforces `replace` policy in one place.** `sessionMutable` / `readOnly` filtering, unknown-key dropping, and structural-equality skipping all live inside `replace` — there is no other code path that constructs a replace dispatch.
- **The handle exposes `current` as `IObservable`, not as a property or a method.** This matches how the picker already uses `derived(...)` autoruns and removes the side-effect-on-property-read smell that the today's `getSessionConfig(id)` has.
- **Migration shape.** `BaseAgentHostSessionsProvider` keeps its current public surface for one or two changes — the seven `IAgentHostSessionsProvider` methods become thin pass-throughs to `this.sessionConfig.for(id).{…}` — and gets removed once the call sites (pickers, JSONC editor, FS provider) have moved over to `provider.sessionConfig.for(id)`. The lifecycle methods (`beginUntitled` / `commitUntitled` / `abandonUntitled` / `forgetRunning` / `ingestWireChange`) are wired up inside `BaseAgentHostSessionsProvider`'s existing `_createNewSessionForType` / `_commitNewSession` / `_handleSessionRemoved` / `_handleConfigChanged` — those four methods are the only edits required in the provider for the lifecycle wiring.

## Out of scope

- Pluggable seed sources, validators, or derived-value hooks. The protocol's design philosophy assigns "what config does this session have" to the agent side, not the renderer; speculative extension points on the renderer side conflict with that.
- Restructuring how config is persisted on the agent side (`agentService.ts` / `agentSideEffects.ts`).
- The auto-approve picker recognition logic in [agentHostAutoApprovePicker](../../docs/agent-host-auto-approve-picker.md) — that's a separate concern that *consumes* this store but doesn't belong inside it.
