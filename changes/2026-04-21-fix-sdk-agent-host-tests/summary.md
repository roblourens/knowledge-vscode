# Fix real-SDK agent host tests — skip plan-mode, fix subagent busy-spin

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/fix-sdk-agent-host-tests
**VS Code SHA at finalize:** a92cbe70e9
**PR:** [#311993](https://github.com/microsoft/vscode/pull/311993)

## What was done

Two changes to `src/vs/platform/agentHost/test/node/protocol/toolApprovalRealSdk.integrationTest.ts`, the env-gated real-SDK suite that runs against the live Copilot SDK + endpoint:

1. **Skipped `planning-mode session-state writes are auto-approved in default mode`** (`test.skip` with a TODO comment) because the public `@github/copilot-sdk` doesn't expose the API surface needed to put a session into plan mode or to respond to the SDK's `exit_plan_mode.requested` event. The test cannot pass until the public SDK adds those surfaces.
2. **Fixed the `subagent` test's busy-spin** in the background `approvalLoop` by tracking processed `serverSeq` values from `IActionEnvelope`, so already-handled `session/toolCallReady` notifications aren't repeatedly re-approved. Final dedupe key is `serverSeq` (per the Copilot reviewer's comment), not `toolCallId` — same `toolCallId` can legitimately reappear in re-confirmation notifications.

No production code changes — the agent host itself is unchanged. The earlier elicitation-handler work (in `copilotAgent.ts` + `copilotAgentSession.ts`) was thrown away once we realized the public SDK can't trigger plan mode in the first place.

## Key decisions

- **Skip the planning-mode test rather than try to make it pass with workarounds.** The public SDK surface is missing both halves (no `agentMode: 'plan'` on `MessageOptions`; no `Session.respondToExitPlanMode()`). Trying to fake plan mode by detecting a `[[PLAN]]` prompt prefix or by hand-wiring the protected `onExitPlanMode` callback would all be paper over the real gap. Better to skip with a precise comment so the next person doesn't repeat the dead-end investigation.
- **Dedupe by `serverSeq`, not by `toolCallId`.** First fix used `toolCallId` and was caught by Copilot review: a tool call can have multiple `toolCallReady` notifications (e.g. re-confirmation while running), so id-based dedupe would silently drop legitimate later confirmations. `serverSeq` is per-notification and monotonic — exactly the right key for "have I processed this exact notification already?".
- **Throw away the in-progress elicitation handler.** It was 145 lines in `copilotAgentSession.ts` translating the SDK's `ElicitationContext` into our `ISessionInputRequest` and back. It was correct as far as it went, but with no way to put the session into plan mode in the first place, the elicitation would never fire and the code would have shipped dead. Better to remove it from the change and re-introduce later when the SDK gains the entry point.

## What went wrong or was misunderstood

- **Initially assumed the `onExitPlanMode` callback was the wiring gap.** It IS in `SessionOptions`, but `protected` and not exposed via `ResumeSessionConfig` in the public SDK. Then assumed `agentMode: 'plan'` on the SDK's `SendOptions` was reachable. It isn't — `MessageOptions` in `@github/copilot-sdk` has no `agentMode` field at all. **Prevented by:** new `gotcha:` on `copilot-agent-provider.md` documenting the full public-vs-private SDK split for plan mode, with the specific differences enumerated.
- **Assumed `[[PLAN]]` prompt prefix had semantic meaning at the SDK layer.** It doesn't — that's a CLI-host convention used by the Copilot CLI itself to flip its in-process system-prompt mode. The SDK has no notion of it. The user's manual test (sending `[[PLAN]]` against the agent-host SDK path) confirmed nothing happened. **Prevented by:** the same public/private SDK gotcha, which makes clear the public SDK has no plan-mode trigger of any kind.
- **Re-discovery: extension and agent host import different SDK packages.** The extension imports `@github/copilot/sdk` (private surface from a sibling export of the same npm package); the agent host imports `@github/copilot-sdk` (a separately-published public package). Took several rounds of grepping the type definitions before this clicked. The existing testing-doc gotcha at line 129 even mis-attributed the planning-mode failure to "`SessionOptions.onExitPlanMode` is never wired into `CopilotAgentSession`" — which sounds like a wiring bug but is actually a missing-surface problem. **Prevented by:** new gotcha on `copilot-agent-provider.md` (where the SDK-import-related stuff already lives) plus updated cross-reference from the rewritten testing-doc gotcha.
- **`waitForNotification` looks like a "wait and consume" but is actually "wait and filter".** The subagent approval loop was busy-spinning for the same reason every time: matched notifications stay in the queue, so re-running the same predicate matches the same one immediately. The original guard `if (!action.confirmed)` did nothing because the very notification we'd just dispatched a `toolCallConfirmed` for was the next thing the predicate matched. **Prevented by:** new `gotcha:` on `testing.md` documenting that `waitForNotification` does not consume, with a concrete dedupe-by-`serverSeq` recipe — applies to any background-polling loop in protocol or real-SDK integration tests.
- **First dedupe attempt used `toolCallId`.** Caught by the Copilot reviewer on the PR: the same `toolCallId` can legitimately reappear in multiple notifications. **Prevented by:** the same `waitForNotification` gotcha, which now explicitly says "dedupe by `serverSeq`, not by domain id."

## What we learned

- The existing testing-doc gotcha at line 129 (added by the SDK bump session on 2026-04-21) had the right instinct — flag both failing tests as known-broken and out of scope for casual SDK-bump work — but mis-diagnosed `planning-mode`. The replacement gotchas are more useful because they explain *why* and link to the public/private SDK split.
- The `serverSeq` field on `IActionEnvelope` is the right dedupe key for any test loop that polls the notification stream. Not just for `toolCallReady` — for *anything*. Worth thinking of `serverSeq` as "the notification's identity" rather than as a sequence number.

## Doc updates

- **`docs/testing.md`** — replaced the joint `planning-mode` + `subagent` failing-tests gotcha (line 129) with two more precise entries: `subagent` is now fixed (busy-spin from `waitForNotification` not consuming, dedupe by `serverSeq`); `planning-mode` is `test.skip`'d because the public SDK lacks the API surface (cross-link to `copilot-agent-provider.md`). Added a standalone `waitForNotification` gotcha covering the broader pattern.
- **`docs/copilot-agent-provider.md`** — added a new `gotcha:` documenting the public vs private SDK split (`@github/copilot-sdk` vs `@github/copilot/sdk`), enumerating the specific plan-mode differences observed at `@github/copilot@1.0.34` / `@github/copilot-sdk@0.2.2`. This is the load-bearing context for the skipped planning-mode test.
