# Plan: Stop the customization publish/echo treadmill

The user's session log shows the client republishing the same `vscode-synced-customization` bundle to the agent host indefinitely (~2,200 server-echoed `session/customizationsChanged` over 80 minutes, ~445 client `session/activeClientChanged` dispatches across 5 sessions, all with the same content nonce `-672038454`). It's not a runaway hot loop — it's a steady-state amplifier where any prompt-service tick re-bundles, re-publishes, and re-syncs unchanged customizations. Fix it by content-deduping at three points: the bundler, the per-agent observable, and the per-session active-client dispatch.

## Knowledge context used
- [agent-host-customizations](../../docs/agent-host-customizations.md) — confirms that the customization-ref forwarding (in `AgentHostSessionHandler`) is a separate concern from the per-file item providers, so the loop lives in the ref-publishing path, not the item providers.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md) — confirms the contract: customization refs flow through the protocol via `ISessionActiveClient`, and the handler re-dispatches `activeClientChanged` whenever its `customizations` observable changes.

## Approach

The chain that needs deduping (in order of where the work originates):

1. **`SyncedCustomizationBundler.bundle()`** in `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts` always `del`s the in-memory tree and rewrites every file, even when the resulting content nonce is identical to `_lastNonce`. We compute the nonce from file contents but never use it as a short-circuit. Cache the previous bundle's `(filesKey → contentNonce)` plus the resulting `IBundleResult`, and on a subsequent `bundle()` call: read all sources, hash, and if the new nonce equals `_lastNonce`, return the cached `IBundleResult` *without* touching the FS. This kills the "same bundle, same nonce, but re-published" amplification at the source.

2. **Per-agent `customizations` observable** in both `agentHostChatContribution.ts` (`_registerAgent`) and `remoteAgentHost.contribution.ts` (`_registerAgent`). `customizations.set(refs, undefined)` always fires because `observableValue` uses reference equality and `resolveCustomizationRefs` always builds a fresh array. Switch to `observableValue` constructed with a deep-equal `JsonEqualityComparer`-style comparator over `CustomizationRef[]` (or a small inline `customizationRefsEqual` helper that compares uri + nonce + displayName + description per entry). With this in place, an unchanged bundler result yields a no-op `set()` and the `autorun` in `AgentHostSessionHandler` doesn't re-dispatch.

3. **Coalescing the upstream events** in both contributions. Right now `Event.any(onDidChangeCustomAgents, onDidChangeSlashCommands, onDidChangeSkills, onDidChangeInstructions)` fires `updateCustomizations` once per fan-out event — but skills are guaranteed to fire both `cachedSkills` and `cachedSlashCommands`, and any plugin churn fires all four. Wrap the trigger in `Event.debounce` (or a small `RunOnceScheduler` / `Throttler`) so a burst of upstream events collapses to a single `updateCustomizations()` invocation per microtask/tick. This isn't strictly required after fixes 1+2, but it removes the most expensive part — re-reading every customization file on every fan-out event — even when content actually does change.

The three fixes are independent and compose: 1 makes the bundler a no-op when nothing changed, 2 makes the observable a no-op when bundler returns the same ref set, and 3 makes the trigger fire once per real change instead of once per fan-out event.

Out of scope for this plan: server-side amplification (each `activeClientChanged` produces a `loading`→`loaded` pair on the server even when content hasn't changed — see the `vscode-synced-customization` echoes in the log). That would require an agent-host-side change in `agentPluginManager` / `copilotAgent.ts` to short-circuit re-syncs when `(uri, nonce)` is unchanged, and is best tracked separately.

## Steps

1. **Bundler nonce short-circuit.** In `SyncedCustomizationBundler.bundle()` compute the would-be nonce *before* deleting/writing: read every source file in parallel, build the same sorted `hashParts` it currently builds, and compute `nonce`. If `nonce === this._lastNonce` and a cached `IBundleResult` exists, return the cached result without any FS mutation. Otherwise fall through to the existing del/write path and cache the new result. Acceptance: on a second call with identical sources, no `IFileService.del` / `writeFile` is observed and the same `IBundleResult` is returned (`syncedCustomizationBundler.test.ts` already has the harness for this).
2. **Content-equality observable for refs.** Add a small `customizationRefsEqual(a, b)` helper alongside `resolveCustomizationRefs` (in `agentHostLocalCustomizations.ts`) and use it as the equality comparator when constructing the `observableValue<CustomizationRef[]>('agentCustomizations', [])` in both `agentHostChatContribution.ts:_registerAgent` and `remoteAgentHost.contribution.ts:_registerAgent`. Acceptance: setting equal refs is a no-op (`autorun` doesn't fire).
3. **Coalesce the upstream trigger.** In both `_registerAgent` sites, replace the `Event.any(...)( () => updateCustomizations() )` with `Event.debounce(Event.any(...), () => undefined, 0)` (or a `RunOnceScheduler` if a slightly larger window is preferred — match whatever the surrounding code uses for similar coalescing) so that a single tick collapses fan-out events. Acceptance: a burst of all four events fires `updateCustomizations` once.
4. **Tests.** Extend `syncedCustomizationBundler.test.ts` with a "second bundle with identical sources is a no-op" case, and add a small unit test for `customizationRefsEqual`. The contribution-level wiring is already covered by `agentHostChatContribution.test.ts`; add a regression case there asserting that two consecutive `updateCustomizations()` runs with unchanged sources produce a single `activeClientChanged` dispatch (use the existing test connection's dispatched-actions log).
5. **Manual verification with the user's repro.** Reproduce by opening the Agents window with a `vscode-team-kit` plugin and a non-trivial set of synced customizations, dispatch a turn, and confirm the chatty `session/customizationsChanged` echoes stop after first publish (no echoes during steady state, only on real edits).

## Relevant files

- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts` — add nonce-based short-circuit at the top of `bundle()`; cache last `IBundleResult`.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostLocalCustomizations.ts` — add and export `customizationRefsEqual` next to `resolveCustomizationRefs`.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts` — pass equality comparator to `observableValue`; wrap `Event.any(...)` in `Event.debounce`.
- `src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts` — same two changes as the local contribution.
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/syncedCustomizationBundler.test.ts` — add no-op-on-unchanged test.
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostChatContribution.test.ts` — add dedupe regression test.

## Verification

1. `node ./scripts/test.sh --grep "SyncedCustomizationBundler"` — confirms the new no-op-on-unchanged behavior and that existing bundle/rebundle/multi-authority cases still pass.
2. `node ./scripts/test.sh --grep "agentHostChatContribution"` — confirms the dedupe regression test plus existing customizations / active-client flows.
3. Repro harness from the user: open Agents window, attach to remote agent host with a synced customizations bundle, send any turn, watch the `loop.log`-style trace and confirm no `session/customizationsChanged` echoes after the first publish at steady state.

## Decisions

- **Three layers of dedupe, not one.** Each of bundler / observable / event trigger fixes a distinct amplification. Doing only one (e.g. just the bundler) still leaves `updateCustomizations` running 4× per change due to event fan-out; doing only the observable still re-bundles every time. They're cheap and independent.
- **Equality is content-shallow.** `CustomizationRef` is a small, flat object (`uri`, `displayName`, `description`, `nonce`); a hand-rolled equality function is enough — no need to pull in `equals` from `vs/base/common/objects`.
- **No server-side change in this plan.** The server's loading→loaded re-emit on identical content is real but separate — fixing the client stops sending unchanged refs in the first place, which is enough to make the protocol quiet.

## Risks and open questions

- **Hidden assumption that bundler always rewrites.** Nothing in the AHP layer should care whether the in-memory FS was rewritten — consumers read by URI on demand, and the URI is stable per-authority. Worth a quick scan of `agentHostFileSystemService` consumers to be sure no one expects a `del`/`write` event as a refresh signal.
- **Event.debounce window.** Picking `0` (microtask) is safe; picking >0 could delay legitimate updates if the user toggles a customization. Prefer `0` unless we observe a remaining hot loop.
- **CustomizationRef equality nuance.** If `description` legitimately changes without `nonce` changing (e.g. the "N customizations synced" string), we should still treat it as a change. The `customizationRefsEqual` helper should compare all fields (incl. description), not just `(uri, nonce)`.

## Docs that will need updating

- `[agent-host-customizations](../../docs/agent-host-customizations.md)` — the "Caching" row mentions the local provider has no caching; the bundler fix introduces a cache. Add a `gotcha` (or extend the existing customizations-flow note) explaining that `SyncedCustomizationBundler` short-circuits identical content and that the per-agent `customizations` observable is content-equal-comparing, so consumers must NOT rely on bundler/observable churn as a "something might have changed" signal.
- `[agent-host-session-handler](../../docs/agent-host-session-handler.md)` — the customization-ref forwarding section should note that `activeClientChanged` only re-dispatches when refs are content-different, not on every observable assignment.
