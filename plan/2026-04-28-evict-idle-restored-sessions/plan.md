# Plan: Evict Idle Restored Sessions

The Agent Host server keeps every restored session's full `Turn[]`/`ResponsePart[]` tree in `AgentHostStateManager._sessionStates` for the entire process lifetime, because `AgentService.unsubscribe` is a no-op. There is also a *client-side* leak: the workbench provider `BaseAgentHostSessionsProvider` holds a refcounted `IAgentSubscription` for every session the user has ever viewed or whose config was inspected, releasing it only on permanent session deletion or provider dispose — so even if the server decremented refcounts, the wire `unsubscribe` would never be sent. This plan fixes both: a server-side refcount that evicts idle restored sessions on last unsubscribe, plus a client-side change that releases the provider's `_sessionStateSubscriptions` ref when the session is no longer being actively viewed. Active sessions and sessions that were created (not restored) in this server lifetime are preserved.

## Knowledge context used

- [agent-host-topology](../../docs/agent-host-topology.md) — Establishes "the agent runs without a client"; eviction must distinguish *active backend session* (must stay) from *idle cached restored history* (safe to drop and re-fetch from the SDK).
- [agent-host-protocol](../../docs/agent-host-protocol.md) — Defines `subscribe`/`unsubscribe` semantics and the snapshot/replay handshake; the new refcount must keep snapshot rehydration working when a previously-evicted session is re-subscribed.
- [copilot-agent-provider](../../docs/copilot-agent-provider.md) — Confirms `agent.getSessionMessages()` is the canonical re-source for restored history; eviction is safe because rehydration is cheap and idempotent.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md) — Shows how the workbench-side handler subscribes/unsubscribes; informs the multi-viewer scenarios the refcount must handle.
- changes/2026-04-25-cache-list-sessions-client/summary.md — Recent precedent for client-side caching choices that informed the bias toward server-side eviction here.

## Approach

The fix has four pieces. First, **wire the existing `IConnectedClient.subscriptions` set into `AgentService` as an authoritative refcount** so the server tracks how many connected clients hold each resource. Second, **evict on last unsubscribe and on client disconnect**, but only for *restored* sessions and only when the session has no `activeTurn`. Third, **mark restored vs. created sessions** so eviction never throws away in-process state that cannot be reconstructed from the SDK. Fourth — and load-bearing for the whole plan to actually take effect in the Agents app — **change `BaseAgentHostSessionsProvider` so that `_sessionStateSubscriptions` is only held while the session is actively being viewed**, not for the entire provider lifetime.

The natural seam is `ProtocolServerHandler`: the `subscribe` request handler at `protocolServerHandler.ts` line 325, the `unsubscribe` notification branch at line 176, and the `transport.onClose` handler around line 200. All three already touch `client.subscriptions`; they will additionally call new `IAgentService.addSubscriber(resource, clientId)` / `removeSubscriber(resource, clientId)` methods. The refcount itself lives in `AgentService` (a `ResourceMap<Set<string>>` keyed by resource → set of clientIds), not in `AgentHostStateManager`, because subscription is a protocol concern; the state manager just owns lifecycle. When the last subscriber is removed, `AgentService` consults `_stateManager.getSessionState(resource)` and, if the session is restored and has no `activeTurn`, calls `_stateManager.removeSession(resource)` (the existing primitive that evicts without firing `SessionRemoved`). For subagent URIs, eviction targets the parent session entry only when no subagent siblings remain subscribed.

Marking restored vs. created is a single boolean flag on `SessionState` (`_meta.restoredFromBackend: boolean`), set true in `AgentHostStateManager.restoreSession` and left false in `createSession`. This is the eviction gate: we never drop a session whose authoritative state lives only in this process. Subagent restored sessions inherit the flag through `_restoreSubagentSession`. Active turns are an absolute veto: even a restored session with `activeTurn !== undefined` stays resident, so streaming responses to a viewer that just disconnected are not corrupted, and the "agent runs without a client" invariant from `agent-host-topology` is preserved.

To bound worst-case retention before any client connects (a server forked for a single CLI run that disconnects abruptly), we will also evict on `transport.onClose` for every entry in `client.subscriptions`, treating disconnect as an implicit unsubscribe. The existing `_rejectPendingReverseRequests` call at line ~205 is the right co-location.

The client-side change targets `_ensureSessionStateSubscription` in `baseAgentHostSessionsProvider.ts:1052`. Today this method seeds `_runningSessionConfigs` and `_meta.git` from the live `SessionState` and keeps the subscription forever. The two callers — `getSessionByResource` (line 469) and `getSessionConfig` (line 590) — both run in contexts where the data is needed *now* but doesn't need to keep flowing once cached and once the user navigates away. The fix introduces a small per-session refcount inside the provider: callers obtain a lease via a new `_acquireSessionStateLease(sessionId): IDisposable`; when all leases are released, the underlying `IAgentSubscription` ref is disposed (after a short debounce to absorb open→close→open churn). The session-handler chat content path already manages its own `_sessionSubscriptions` (`agentHostSessionHandler.ts:331`) and is unaffected — those already release correctly on chat-editor close (`agentHostSessionHandler.ts:535`). The provider's lease is what closes when no view holds it.

Findings #2 (`copilotAgent._activeClients` / `_pendingFirstTurnAnnouncements` not cleaned in `_destroyAndDisposeSession`) and #3 (`baseAgentHostSessionsProvider._refreshSessions` missing `_sessionStateSubscriptions.deleteAndDispose`) are deliberately scoped OUT of this plan — they are smaller and independent and will be follow-ups. Note that Finding #3 becomes less impactful once Phase 5 lands, since the lease itself enforces correct disposal in normal flow.

## Steps

### Phase 1 — State manager support

1. Add `_meta.restoredFromBackend: boolean` to the `SessionState._meta` shape in `agentHostStateManager.ts`. Set true in `restoreSession` (line 163) and ensure `createSession` (line 130) leaves it false/undefined. Acceptance: existing snapshot tests still pass; new field is plumbed through `getSessionState` / `getSnapshot` consumers without leaking into the wire snapshot type if it is not already part of `_meta`.

2. Add `AgentHostStateManager.isRestoredAndIdle(session: URI): boolean` returning true iff `_sessionStates.has(session)`, `_meta.restoredFromBackend === true`, and `state.activeTurn === undefined`. Acceptance: unit-tested directly in `agentHostStateManager.test.ts`.

### Phase 2 — Refcount in AgentService

3. In `agentService.ts`, add `private readonly _resourceSubscribers = new ResourceMap<Set<string>>()`. Add public methods `addSubscriber(resource: URI, clientId: string): void` and `removeSubscriber(resource: URI, clientId: string): void` to `IAgentService`. `addSubscriber` ensures a Set exists and adds the clientId. `removeSubscriber` removes the clientId, and when the Set is empty deletes the entry and calls `_maybeEvictIdleRestoredSession(resource)`.

4. Implement `_maybeEvictIdleRestoredSession(resource: URI)`. It returns early if `_resourceSubscribers.has(resource)` (someone still subscribed) or if the resource is a subagent URI whose parent session still has any subscriber (use `parseSubagentSessionUri`). Otherwise it calls `_stateManager.isRestoredAndIdle(resource)` and, on true, `_stateManager.removeSession(resource)`. Trace-log the eviction.

5. Replace the `unsubscribe(resource)` no-op body (line ~470 in `agentService.ts`) with a call into `removeSubscriber` *only if* the call site supplies a clientId. Add an overload / second method `unsubscribeForClient(resource, clientId)` rather than overloading the existing public method, to keep the IPC-shaped `unsubscribe(resource)` stable for callers that do not have a clientId (in-process tests). Acceptance: existing direct callers compile unchanged.

### Phase 3 — Wire into ProtocolServerHandler

6. In `protocolServerHandler.ts`:
   - In the `subscribe` request handler (line 325), after `client.subscriptions.add(params.resource)`, call `this._agentService.addSubscriber(URI.parse(params.resource), client.clientId)`.
   - In the `unsubscribe` notification branch (line 176), after `client.subscriptions.delete(msg.params.resource)`, call `this._agentService.removeSubscriber(URI.parse(msg.params.resource), client.clientId)`.
   - In `transport.onClose` (line ~200), for every `resource` in `client.subscriptions`, call `removeSubscriber`. Do this before `this._clients.delete`.
   - In `_handleInitialize` and `_handleReconnect` where `initialSubscriptions` / `params.subscriptions` are added to `client.subscriptions`, also call `addSubscriber` for each.

### Phase 5 — Client-side: release provider-held subscriptions

6a. In `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts`, refactor `_sessionStateSubscriptions` from "created once, held forever" to a leased model:
   - Replace the value type with `{ ref: IReference<IAgentSubscription<SessionState>>; storeDisposable: DisposableStore; leases: number; idleTimer?: IDisposable }`.
   - Add `_acquireSessionStateLease(sessionId: string): IDisposable` that increments `leases`, lazily creating the entry as `_ensureSessionStateSubscription` does today; the returned disposable decrements and, when `leases` reaches 0, schedules disposal via a small idle debounce (e.g. 5 seconds via `disposableTimeout`) to absorb churn. If a new lease arrives during the debounce, cancel the timer.
   - Convert call sites: `getSessionByResource` (line 469) currently calls `_ensureSessionStateSubscription` and returns immediately; replace with a call that acquires a lease *owned by the returned `ISession`'s lifecycle*. Since `ISession` is reused across `getSessionByResource` calls, the cleanest place is to attach the lease to the session adapter when first created and dispose it from the adapter's existing dispose. If `ISession` adapters in `_sessionCache` are not disposable today, hang the lease off a `DisposableMap<sessionId, IDisposable>` keyed alongside `_sessionCache` and dispose entries when sessions are removed (covers Finding #3 along the way).
   - Convert `getSessionConfig` (line 590): it is a query that should not keep a long-lived subscription. Acquire a lease for the duration needed to seed the config, then release. If the cached `_runningSessionConfigs` already has data, do not re-acquire.
6b. Audit other in-tree callers of `_ensureSessionStateSubscription` (search the file) and migrate them to lease-based access.
6c. Confirm the comment at line 1048 ("reference-counted by `IAgentConnection.getSubscription`, so when the session handler is also subscribed this shares the existing wire subscription") still holds: the session handler's per-view `_sessionSubscriptions` (`agentHostSessionHandler.ts:331`) and the provider's lease both feed the same client-side `AgentSubscriptionManager` refcount; only when both reach zero does the wire `unsubscribe` fire.

### Phase 6 — Tests

7. Unit tests for the new provider lease in `src/vs/sessions/contrib/agentHost/test/browser/localAgentHostSessionsProvider.test.ts`: acquiring then releasing a single lease drops the underlying ref (after debounce); two overlapping leases share the same ref; a new lease during debounce cancels the disposal; provider dispose disposes any held leases; reacquire after disposal works; existing `sessionUnsubscribeCounts` assertions (lines 946-950) tighten to assert exactly one wire `unsubscribe` after the last lease is released.

8. Mirror the same in `src/vs/sessions/contrib/remoteAgentHost/test/browser/remoteAgentHostSessionsProvider.test.ts` (already has parallel `sessionUnsubscribeCounts` assertions at lines 992-1016).

9. Unit tests in `src/vs/platform/agentHost/test/node/agentHostStateManager.test.ts` for `isRestoredAndIdle` covering: created session (false), restored session with no active turn (true), restored session with active turn (false), unknown resource (false). Acceptance: tests added in the existing suite, not at file end.

10. Unit tests in `src/vs/platform/agentHost/test/node/agentService.test.ts` for the refcount: add/remove single subscriber evicts a restored idle session; add/remove second subscriber while first is present does NOT evict; eviction does not happen for created sessions; eviction does not happen while `activeTurn` is set; subagent eviction respects sibling subscribers under the same parent.

11. Protocol-level integration test in `src/vs/platform/agentHost/test/node/protocol/` (new file `subscriptionEviction.integrationTest.ts` patterned on `testHelpers.startServer`): connect two protocol clients, both subscribe to the same restored resource, disconnect one — `_sessionStates` size is unchanged; disconnect the second — `_sessionStates` size decreases by one; new third client can re-subscribe and gets a fresh snapshot via `restoreSession`.

12. Real-SDK soak in `toolApprovalRealSdk.integrationTest.ts` style (env-gated, opt-in): loop subscribe → unsubscribe across the existing worktree+terminal scenario (line 612) and subagent scenario (line 759) N times in the same forked agent-host process; assert via a new debug RPC (or via inspector heap-snapshot harvesting — see Verification) that `_sessionStates.size` returns to baseline. This step is the regression net for memory.

## Relevant files

- `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts` — Refactor `_sessionStateSubscriptions` to a leased model; add `_acquireSessionStateLease`; migrate `getSessionByResource` (line 469) and `getSessionConfig` (line 590) callers. Reuse `disposableTimeout` from `vs/base/common/lifecycle`.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts` — No code change required; verify that its existing `_sessionSubscriptions` (line 331) and `_releaseSessionSubscription` (line 2509) still cooperate correctly with the provider's lease via `AgentSubscriptionManager` refcount.
- `src/vs/sessions/contrib/agentHost/test/browser/localAgentHostSessionsProvider.test.ts` — Tighten `sessionUnsubscribeCounts` assertions, add lease tests.
- `src/vs/sessions/contrib/remoteAgentHost/test/browser/remoteAgentHostSessionsProvider.test.ts` — Mirror lease tests.
- `src/vs/platform/agentHost/node/agentHostStateManager.ts` — Add `_meta.restoredFromBackend`; add `isRestoredAndIdle`. Reuse the existing `removeSession` (line 188) primitive — do not invent new eviction code paths.
- `src/vs/platform/agentHost/node/agentService.ts` — Add `_resourceSubscribers`, `addSubscriber`, `removeSubscriber`, `_maybeEvictIdleRestoredSession`. Replace the `unsubscribe` no-op (line ~468). Reuse `parseSubagentSessionUri` already imported.
- `src/vs/platform/agentHost/common/agentService.ts` (or wherever `IAgentService` is declared) — Add `addSubscriber` / `removeSubscriber` to the interface.
- `src/vs/platform/agentHost/node/protocolServerHandler.ts` — Three call-site additions in `_handleInitialize`, `_handleReconnect`, the `subscribe` handler, the `unsubscribe` notification branch, and `transport.onClose`.
- `src/vs/platform/agentHost/test/node/agentHostStateManager.test.ts` — New `isRestoredAndIdle` cases.
- `src/vs/platform/agentHost/test/node/agentService.test.ts` — Refcount/eviction cases.
- `src/vs/platform/agentHost/test/node/protocol/subscriptionEviction.integrationTest.ts` — New, modelled on `testHelpers.ts:startServer`.
- `src/vs/platform/agentHost/test/node/protocol/toolApprovalRealSdk.integrationTest.ts` — Optional opt-in soak loop addition.
- `src/vs/platform/agentHost/node/agentHostMain.ts` — `getInspectInfo` (line 153) is already in place; the validation plan uses it without changes.

## Verification

### Automated

1. `npm run compile-check-ts-native` — type-check after the interface change.
2. Run `runTests` against `src/vs/platform/agentHost/test/node/agentHostStateManager.test.ts` and `agentService.test.ts` for the new unit tests.
3. Run the new `subscriptionEviction.integrationTest.ts` via `scripts/test-integration.sh --grep subscriptionEviction`.
4. Run the existing protocol integration suite (`scripts/test-integration.sh --grep "agentHost/protocol"`) to confirm no regression in subscribe/reconnect replay behaviour.
5. Optional opt-in: `AGENT_HOST_REAL_SDK=1 scripts/test-integration.sh --grep toolApprovalRealSdk` followed by the new soak loop; assert `_sessionStates.size` returns to baseline after a configurable iteration count.

### Heap-snapshot regression check

6. Patch `testHelpers.startServer` / `startRealServer` (locally, not committed) to forward `--inspect=0` into the forked agent-host, capture the inspector URL via `getInspectInfo` (`agentHostMain.ts:153`), drive the soak loop, then take before/after heap snapshots through the inspector. Compare `SessionState`, `Turn`, and `ToolCallCompletedState` class counts using `analyzeSnapshot.js` with `@vscode/v8-heap-parser`'s `get_class_counts(['SessionState','Turn','ToolCallCompletedState'])`. After-count must equal before-count for restored sessions whose subscribers all disconnected.

### Manual end-to-end (code-oss-debugging)

7. Manual verification per the [code-oss-debugging](file:///Users/roblou/.copilot/skills/code-oss-debugging/SKILL.md) skill, using a real Code OSS Agents launch:
   - Pick unique paths and ports as described in *Pick Unique Paths and Ports*; capture `CDP_PORT` and an extra free port for `--inspect=$AGENT_HOST_INSPECT_PORT`.
   - Seed `USER_DATA_DIR` from `~/.vscode-oss-agents-dev` per *Seed an Authenticated Profile*.
   - Launch the Agents app per *Launch the Agents App*, additionally arranging for the agent-host utility process to expose an inspector. Two equivalent options: (a) build a temporary launch override that injects `--inspect=$AGENT_HOST_INSPECT_PORT` into the `UtilityProcess` execArgv path in `electronAgentHostStarter.ts:56-60`; (b) use the in-process API `getInspectInfo(true)` from `agentHostMain.ts:153` via a debug command exposed during the run. Prefer option (a) for repeatability.
   - Connect Chrome DevTools to `127.0.0.1:$AGENT_HOST_INSPECT_PORT`. Take an initial heap snapshot labelled "baseline" before opening any session.
   - In the Agents UI, open three pre-existing historical sessions sequentially (each open triggers `subscribe` → `restoreSession`). Take a heap snapshot labelled "after-open-3".
   - Close each of the three session views (each triggers `unsubscribe`). Wait ~2s for any pending I/O. Take a heap snapshot labelled "after-close-3".
   - In DevTools, compare snapshots: "after-close-3" `SessionState` count must equal "baseline" + active-session count (typically 0 if no active turn). The retained-size of `AgentHostStateManager` must drop close to baseline. Capture screenshots of the comparison and of the Agents UI between each step (`01-baseline`, `02-after-open-3`, `03-after-close-3`, `04-devtools-comparison`).
   - Repeat with one session left subscribed: open three, close two — `SessionState` count drops by 2, not 3.
   - Repeat with an active streaming session: open a session and send a long prompt, close the view while the agent is still streaming — `SessionState` count must NOT decrease (active-turn veto). Re-open the same session and confirm streaming continued without corruption.
   - Preserve all screenshots out of `RUN_DIR` to a durable location per the *Cleanup* section, then close cleanly.

### Regression net (no new behaviour broken)

8. Run the workbench unit tests for `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts` to confirm session refresh / removal flows still work.
9. Run `scripts/test-integration.sh` for the broader agentHost suite.
10. Smoke the multi-viewer scenario manually: open the same session URI in two Agents windows attached to the same agent-host; close one window — the other must continue receiving updates without interruption (refcount > 0).

## Decisions

- **Refcount lives in `AgentService`, not `AgentHostStateManager`.** The state manager owns lifecycle; subscription is protocol concern. This keeps `AgentHostStateManager` reusable for future non-protocol callers (e.g. an embedded host) and avoids cross-coupling.
- **Eviction is conditional on `restoredFromBackend === true`.** Sessions created in-process have authoritative state that cannot be re-fetched from the SDK; evicting them would lose data. The flag is set exactly once, in `restoreSession`.
- **`activeTurn !== undefined` is an absolute veto.** Preserves "agent runs without a client" from `agent-host-topology` and prevents corrupted streaming.
- **Eviction uses the existing `removeSession`, not `deleteSession`.** Clients are not told the session is gone — it still exists on the backend and will be rehydrated on next subscribe.
- **Subagent URIs participate but only evict the parent when no sibling subagents are subscribed.** Reuses `parseSubagentSessionUri`.
- **`unsubscribe(resource)` keeps its existing no-clientId signature; new `unsubscribeForClient(resource, clientId)` is added.** Preserves backwards compatibility with non-protocol callers.
- **Client-side provider lease is required for the server-side fix to actually take effect.** Without it, the workbench `_sessionStateSubscriptions` keeps the client-side `AgentSubscriptionManager` refcount above zero forever, the wire `unsubscribe` is never sent, and the server-side eviction never triggers in the Agents app. This is why Phase 5 is part of this plan rather than a follow-up.
- **Lease debounce is short (~5s) and configurable.** Absorbs the open→close→open churn pattern (e.g. user clicks the wrong session, immediately reopens) without holding state indefinitely.
- **Scoped OUT of this plan:** Findings #2 (`copilotAgent._activeClients` cleanup) and #3 (`baseAgentHostSessionsProvider._refreshSessions` subscription disposal). Both are smaller, independent follow-ups; #3's impact is reduced once the lease lands because correct lease ownership covers the normal flow.

## Risks and open questions

- **Re-subscribe latency.** First subscribe after eviction pays the `agent.getSessionMessages()` cost again. Validation plan step 7's "open three, close, re-open one" exercises this. If perceived latency is too high, a future LRU/TTL warm cache can be added on top of the refcount layer without re-architecting.
- **Initial subscriptions in `_handleInitialize`/`_handleReconnect`.** The handshake adds entries to `client.subscriptions` directly; missing the corresponding `addSubscriber` call would over-decrement on disconnect. Mitigated by step 6's explicit handshake wiring and integration test.
- **Reverse RPC during eviction race.** If a tool call completes during the same tick as eviction, the state-manager update would target a now-evicted session. Mitigated because eviction only runs when `activeTurn === undefined`, but warrants an integration test that interleaves tool completion with last-unsubscribe.
- **Multi-window same-machine.** Two Agents windows hitting the same in-process agent host both register as clients with distinct clientIds — refcount handles this. Verified manually in step 10.
- **Stale `_runningSessionConfigs` after lease release.** If a session's config changes server-side while no client lease is held, the cached value is stale until the next lease. Acceptable: configs change rarely; next view-open re-subscribes and re-seeds. Document in the new retention doc.
- **Lease ownership for `getSessionByResource`.** This call returns an `ISession` that may outlive any single caller. Plan attaches the lease to the session adapter's lifecycle; if `ISession` adapters are not currently disposable, a `DisposableMap<sessionId, IDisposable>` keyed alongside `_sessionCache` is the alternative. Confirm during implementation Discovery.

## Docs that will need updating

- [agent-host-protocol](../../docs/agent-host-protocol.md) — Document that the server tracks per-client subscriptions and may evict idle restored session state on last unsubscribe; clarify that re-subscribe transparently rehydrates.
- [agent-host-topology](../../docs/agent-host-topology.md) — Add a paragraph distinguishing *active backend session* (always resident) from *cached restored history* (evictable), reinforcing "agent runs without a client" while explaining the memory bound.
- [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md) — Document the new lease pattern for `_sessionStateSubscriptions`; flag that providers must release the lease when the session is no longer being viewed.
- NEW DOC: `agent-host-state-retention` — Covers `_sessionStates` ownership, the `restoredFromBackend` flag, the server-side refcount/eviction policy, the client-side provider lease, end-to-end refcount flow, and operator-visible behaviour. Covers paths: `src/vs/platform/agentHost/node/agentHostStateManager.ts`, `src/vs/platform/agentHost/node/agentService.ts`, `src/vs/platform/agentHost/node/protocolServerHandler.ts`, `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts`.
