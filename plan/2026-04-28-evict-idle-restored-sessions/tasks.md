# Tasks: Evict Idle Restored Sessions

## Phase 1 — State manager

1. [x] Add tracking for restored-from-backend sessions and set it in `AgentHostStateManager.restoreSession` (`src/vs/platform/agentHost/node/agentHostStateManager.ts`). Confirm `createSession` does not set it.
   - depends on: none
   - **Deviation**: implemented as private `_restoredSessions: Set<string>` rather than `SessionState._meta.restoredFromBackend`. `_meta` is the on-wire `SessionMeta` shape that ships to clients; the restored-from-backend flag is purely server-internal eviction policy and should not leak through the protocol.

2. [x] Add `AgentHostStateManager.isRestoredAndIdle(session: URI): boolean` (returns true iff session exists, in `_restoredSessions`, and `activeTurn` is undefined).
   - depends on: task #1

## Phase 2 — Refcount in AgentService

3. [x] Add `_resourceSubscribers = new Map<string, Set<string>>()` to `AgentService`. Add `addSubscriber` / `removeSubscriber` to `IAgentService`.
   - depends on: none

4. [x] Implement `_maybeEvictIdleRestoredSession(resource: URI)` — early-return if any subscriber remains; for subagent URIs, also early-return if any subagent sibling or the parent has subscribers; otherwise call `_stateManager.removeSession(resource)` when `isRestoredAndIdle` is true. On parent eviction, also drop sibling subagent state via `getSessionUrisWithPrefix`.
   - depends on: tasks #2, #3

5. [x] (Folded into task #3.) The new `addSubscriber` / `removeSubscriber` methods are the per-client API; the existing `unsubscribe(resource)` is now an in-process no-op for legacy callers. No separate `unsubscribeForClient` was needed because `removeSubscriber` already takes `clientId`.
   - depends on: task #4

## Phase 3 — Wire ProtocolServerHandler

6. [x] In `src/vs/platform/agentHost/node/protocolServerHandler.ts`:
   - `subscribe` request handler: idempotent — only add + `addSubscriber` when not already in `client.subscriptions`.
   - `unsubscribe` notification branch: only `removeSubscriber` if `client.subscriptions.delete` returned true.
   - `transport.onClose`: iterate `client.subscriptions`, `removeSubscriber` for each, then clear, then delete the client.
   - `_handleInitialize` / `_handleReconnect` (replay + snapshot branches): `addSubscriber` for each restored entry.
   - `MockAgentService` (test) gets stub `addSubscriber` / `removeSubscriber`.
   - depends on: task #5

## Phase 4 — Client-side provider lease (REQUIRED for end-to-end effect)

7. [x] Refactor `_sessionStateSubscriptions` ownership in `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts` so the wire subscription is released once nothing is touching the session.
   - **Deviation**: dropped the explicit `{ ref, leases, idleTimer }` lease handle in favor of a "keep-alive on access" model with a paired `_sessionStateIdleTimers: DisposableMap<string, IDisposable>`. None of the actual callers (`getSessionByResource`, `getSessionConfig`, the working-directory resolver, the JSONC settings provider, the permission picker) can naturally own a lease handle — they are stateless query methods called repeatedly during a session's active use. A single `_keepSessionStateAlive(sessionId)` helper bumps a 30 s idle timer; once nothing has touched the session for 30 s the underlying ref is disposed and the wire `unsubscribe` flows through `IAgentConnection.getSubscription`'s refcount.
   - depends on: none (parallel with phases 1–3)

8. [x] `getSessionByResource` now calls `_keepSessionStateAlive` instead of `_ensureSessionStateSubscription`. The cached adapter's lifecycle is unchanged; the subscription naturally falls off after the idle window.
   - depends on: task #7

9. [x] `getSessionConfig` similarly calls `_keepSessionStateAlive`. The repeated picker / settings file reads naturally extend the idle timer while the picker is active.
   - depends on: task #7

10. [x] `_ensureSessionStateSubscription` is retained as a private helper invoked by `_keepSessionStateAlive` (it owns the actual `getSubscription` + `onDidChange` wiring). All external callers in the file route through `_keepSessionStateAlive`.
    - depends on: tasks #8, #9

## Phase 5 — Tests

11. [x] Added an idle-release test in `localAgentHostSessionsProvider.test.ts` (`session-state subscription auto-releases after the idle window`) that verifies: initial subscribe, no re-subscribe within the window, exactly one wire `unsubscribe` after the 30 s idle timer fires, and re-subscribe on next access. Existing `removing a session disposes its session-state subscription` continues to cover the explicit-deletion path.
    - depends on: task #10

12. [ ] **Deferred.** Mirror lease tests in `remoteAgentHostSessionsProvider.test.ts`. Both providers share `BaseAgentHostSessionsProvider`; the local-side test exercises the same code path. Worth adding for symmetry before the PR.
    - depends on: task #10

13. [x] Added `isRestoredAndIdle` suite to `agentHostStateManager.test.ts` (5 tests: unknown session, created vs restored, with active turn, after `removeSession`).
    - depends on: task #2

14. [x] Added `subscriber refcount eviction` suite to `agentService.test.ts` (4 tests: created-not-restored stays, restored idle evicts on last drop, multi-subscriber keep-alive, subagent pins parent).
    - depends on: task #4

15. [ ] **Deferred.** Create `subscriptionEviction.integrationTest.ts` modelled on `testHelpers.startServer`. The wire wiring (`ProtocolServerHandler`) is covered by its existing 22-test suite which still passes; an integration test would close the loop end-to-end across the JSON-RPC transport. Worth adding for the PR.
    - depends on: task #6

16. [ ] **Deferred.** Soak loop in `toolApprovalRealSdk.integrationTest.ts`. Useful for the heap-snapshot regression check (task #18) but not required to validate functional correctness.
    - depends on: task #6

## Phase 6 — Validation

17. [ ] Run `npm run compile-check-ts-native`, then unit + integration tests per plan Verification steps 1–4. Fix any failures before proceeding.
    - depends on: tasks #11, #12, #13, #14, #15

18. [ ] Heap-snapshot regression check: locally patch `testHelpers.startServer` to forward `--inspect=0`, harvest before/after snapshots around the soak loop, compare `SessionState` / `Turn` / `ToolCallCompletedState` class counts via `analyzeSnapshot.js`.
    - depends on: task #16

19. [ ] Manual end-to-end with the [code-oss-debugging](file:///Users/roblou/.copilot/skills/code-oss-debugging/SKILL.md) skill per plan Verification step 7: launch Agents app with isolated paths/ports and inspector on the agent-host utility process; open 3 historical sessions, snapshot, close them, snapshot, compare `SessionState` retained-size; repeat with one session left subscribed; repeat with an active streaming session (active-turn veto); preserve screenshots out of `RUN_DIR`.
    - depends on: task #17

20. [ ] Multi-viewer manual smoke: two Agents windows on same agent-host, same session — close one, the other keeps streaming.
    - depends on: task #17

## Discoveries for finalize

- **Server-internal flag, not protocol field.** `restoredFromBackend` is implemented as `AgentHostStateManager._restoredSessions: Set<string>` instead of `SessionState._meta.restoredFromBackend`. `_meta` is `SessionMeta = Record<string, unknown>` on the wire; eviction policy is server-internal and should not leak to clients. `isRestoredAndIdle` consults the private set.

- **Subagent URI eviction has two coupled behaviors that must be preserved together.** `AgentService._maybeEvictIdleRestoredSession` for a subagent URI: (a) early-returns if any subagent sibling OR the parent still has subscribers, and (b) on parent eviction, drops every cached sibling subagent state via `_stateManager.getSessionUrisWithPrefix(parent)`. The materialized turn tree is owned by the parent, so a parent eviction makes the siblings garbage; without the prefix sweep they leak.

- **Client-side lease was simplified to keep-alive.** Plan called for an explicit `IDisposable` lease handle. Real callers can't own one — they're stateless query methods. Replaced with idle-timer release; each access bumps a 30 s timer. This achieves the same wire-level effect (refcount → 0) without forcing every caller to thread a disposable. Trade-off: a worst-case 30 s delay between the last UI interaction and the wire `unsubscribe`. Acceptable for an eviction-policy fix.

- **Pre-existing gap (out of scope):** `_refreshSessions` removes entries from `_sessionCache` / `_runningSessionConfigs` for sessions no longer in `listSessions()`, but does not call `_sessionStateSubscriptions.deleteAndDispose` for them (only `_handleSessionRemoved` does). Now that subscriptions self-release on idle this is no longer load-bearing, but worth a follow-up to drop deterministically.

- **`disposableTimeout` does not auto-dispose its handle when the timer fires.** First pass used `_sessionStateIdleTimers.deleteAndLeak(sessionId)` from inside the timer handler, on the assumption that the disposable was self-cleaning. It is not — the leak detector tripped on every test that exercised the idle path. Fixed by switching to `deleteAndDispose`; calling `clearTimeout` on an already-fired timer is a safe no-op.

- **URI alias confusion at the protocol layer.** `import { URI } from '.../common/state/sessionState.js'` is `type URI = string`. `import { URI } from 'vs/base/common/uri.js'` is the real `URI` class. Tests that pass `URI.parse(s)` into the state manager fail silently (`Map.get` by URI object on a string-keyed map misses). The platform layer takes string URIs end-to-end; tests must pass strings. Caught when `isRestoredAndIdle` returned `false` for a freshly restored session in tests.
