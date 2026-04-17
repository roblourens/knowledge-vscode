# Show loading indicator while agent host sessions authenticate

**Date:** 2026-04-17
**VS Code branch:** roblou/agent-host-loading-indicator
**VS Code SHA at finalize:** 02023fbfff
**PR:** https://github.com/microsoft/vscode/pull/311106

## What was done

Added an `authenticationPending` observable to both the local (`IAgentHostService`) and remote (`RemoteAgentHostSessionsProvider`) agent host providers, surfacing as `loading=true` on cached session adapters until the first authentication pass settles. Both default to `true` at construction so cached sessions show as loading from window-open before any auth has happened.

The flag is **sticky**: once `setAuthenticationPending(false)` is called, subsequent `true` calls become no-ops. This was added after observing two-to-three loading flashes per startup caused by background re-auth passes triggered from `IAuthenticationService.onDidChangeSessions` and `IDefaultAccountService.onDidChangeDefaultAccount`.

While debugging why the indicator wasn't visible at all in the first iteration, also fixed an unrelated latency bug: `LanguageModelsService._resolveAllLanguageModels` always awaited `extensionService.activateByEvent('onLanguageModelChatProvider:<vendor>')`, blocking renderer-registered language model providers (such as `AgentHostLanguageModelProvider`) on extension host startup for 10+ seconds. The method now skips the activation wait when a provider is already registered for the vendor.

## Key decisions

- **Sticky flag over event-driven loading.** The original idea was to toggle the flag around every auth pass. But `_authenticateAllConnections` fires repeatedly (often within the same second) from `onDidChangeSessions` events caused by the act of resolving a token. Flipping the flag back to `true` flickers the UI on already-ready sessions. Sticky semantics matched the user-visible intent: "loading covers initial setup, not every background refresh."
- **Pass the observable down into the adapter, don't subscribe in the contribution.** Each `LocalSessionAdapter` / `RemoteSessionAdapter` derives its `loading` as `(per-session loading) OR authenticationPending.read(reader)`. Cleaner than imperatively flipping per-adapter loading state from the contribution.
- **Fix `_resolveAllLanguageModels` rather than work around it in the agent host.** The blocking `activateByEvent` was a real footgun for any future renderer-side LM provider, not just ours. Adding the early-skip preserves existing behavior for extension-backed providers (where the provider isn't yet registered when the resolver runs) and fast-paths the renderer-side case.
- **Did not dedupe redundant token-push RPCs.** The sticky flag hides the UI symptom; the underlying re-auth feedback loop still does real (idempotent) work each pass. Token-equality skip would cut ~600ms of latency per re-auth but risked breaking edge cases (token rotation, scope changes). Deferred until there's a concrete reason to take it on.

## What we learned

- **`IAuthenticationService.onDidChangeSessions` fires from inside the auth resolution path itself.** Resolving a token can mutate the auth service's session cache (silent refresh, hydration), which fires `onDidChangeSessions`, which loops back into `_authenticateAllConnections`. This isn't documented anywhere. If you wire something to `onDidChangeSessions` on the auth driver path, expect re-entry.
- **Renderer-side language model providers are blocked on extension host activation.** `_resolveAllLanguageModels` was written assuming providers come from extensions. The agent host registers its provider directly from a workbench contribution, but model resolution still waited for `onLanguageModelChatProvider:<vendor>` activation events to settle. Symptom: model picker stays empty for 10+ seconds even though the provider is registered the moment the contribution loads.
- **Auth windows are too short to see without a sticky default.** Per-pass auth completion was 1–600ms in dev. The visible loading state comes almost entirely from the initial-true default, not from observing the toggle in flight.
- **Investigation flow that worked.** Added START/END/toggle log lines at every auth boundary plus model-picker init/change events, ran a few times against a freshly-started server vs. an already-running one, and read the renderer log timeline to find which event sequence caused which visible flash. The model-picker logs surfaced the unrelated `_resolveAllLanguageModels` bug — without that telemetry the symptom would have looked the same as a slow auth pass.

## Doc updates

- None. The two candidate gotchas (sticky `authenticationPending`; renderer-side `_resolveAllLanguageModels` early-skip) were considered for `docs/agent-host-topology.md` but declined: the first is normal design intent rather than load-bearing weirdness, and the second belongs in a future doc dedicated to `LanguageModelsService` (out of scope for this session).
