# Fix subagent tool call grouping, auto-approval, agent name display, and buffer cleanup

**Date:** 2026-04-19
**VS Code branch:** agents/fix-subagent-tool-call-grouping
**VS Code SHA at finalize:** 2935e7d695
**PR:** https://github.com/microsoft/vscode/pull/311258

## What was done

Fixed a regression where subagent tool calls in the local Copilot Agent Host appeared flat at the top level of the chat UI instead of nested under their wrapping `task` tool entry. Along the way, fixed three closely-related bugs in the same area: subagent tools weren't getting auto-approved (workspace reads showed a confirmation dialog), the agent name fell back to the generic "subAgent" label instead of showing the real agent name (e.g. "explore"), and a `_pendingSubagentEvents` buffer leaked when the parent tool completed without ever emitting `subagent_started`.

The fixes span four files:

- **`src/vs/platform/agentHost/node/agentSideEffects.ts`** — Defer `_toolCallAgents` registration for inner subagent tool starts (those carrying `parentToolCallId`). The matching `tool_ready` lacks `parentToolCallId`, so registering at start time routes the result to the wrong session. Also clear `_pendingSubagentEvents` in `completeSubagentSession` so a parent that completes without ever emitting `subagent_started` doesn't leak the buffered events. Downgraded buffering log lines from `info` to `trace`.
- **`src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts`** — `getSubagentMetadata` only reads `agent_type` from the SDK's `task` tool args. The previous `agentName` fallback was speculative; the SDK never emits that field. Removed it.
- **`src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/chatSubagentContentPart.ts`** — Updated the autorun to update `description` and `agentName` *independently*, each gated on whether the field actually changed. The previous single-`_isDefaultDescription`-flag gate dropped the late-arriving `agentName` (which arrives via `subagent_started` after `description` has already been set at `tool_start` time), so the UI fell back to "subAgent".
- (Plus tests; see below.)

Test coverage added at three layers:

- **Unit (platform):** new regression test in `agentSideEffects.test.ts` for `_pendingSubagentEvents` cleanup. Behavioral — drives the events that fill the buffer and asserts no stale state remains after the parent completes.
- **Unit (workbench/UI):** new "Late metadata updates" suite in `chatSubagentContentPart.test.ts` (4 tests): default→real description, real-description→agent-name regression, agent-name not cleared by re-render, no-change preserved.
- **Real-SDK integration:** extended `toolApprovalRealSdk.integrationTest.ts` to assert that the `task` tool's args actually contain `agent_type` (locks in the contract that drove the `copilotToolDisplay.ts` change).

## Key decisions

- **SDK-specific arg parsing belongs in the per-SDK adapter, not the generic mapper.** The Copilot SDK's `task` tool destructures `agent_type` (snake_case). That parsing lives in `copilot/copilotToolDisplay.ts::getSubagentMetadata`. The generic `agentEventMapper.ts` only forwards normalized `subagentAgentName` / `subagentDescription` event fields. The user pushed back when an earlier draft of this fix put SDK arg shape knowledge in the generic mapper — they were right; agentEventMapper is shared with future agent providers and shouldn't know about `task` arg shapes.
- **Independent autorun field updates.** A single "is the description still default?" flag couples description and agent-name updates. They arrive at different times and from different events; gate each update on its own actual-changed check.
- **Defer `_toolCallAgents` registration for inner starts.** The first attempt registered all `tool_start` events the same way, which broke `tool_ready` routing (because `tool_ready` lacks `parentToolCallId`). Defer until the buffered event is drained against the real child session.
- **Buffer cleanup belongs in `completeSubagentSession`.** A parent can complete without ever emitting `subagent_started` (SDK error, child never starts). Without explicit cleanup the buffer accumulates across turns. Add the clear in `completeSubagentSession`, plus a regression test that drives that path.
- **Permission auto-approval lives in `CopilotAgentSession.handlePermissionRequest`.** It checks the request's path against the trusted directories; the bug was upstream — the inner tool was being routed to the wrong session, so the permission check ran in a context where it didn't recognize the workspace as trusted. Fixing the routing fixed the auto-approval transitively. No changes needed in `handlePermissionRequest` itself.
- **Eager auto-ready stays.** The user asked whether the SDK permission flow running in parallel with eager auto-ready was the real issue. Investigated and concluded: eager auto-ready is fine; the wrong-session routing was the actual cause. Don't change the auto-ready timing.
- **Removed the `agentName` fallback.** Investigated the bundled SDK (`node_modules/@github/copilot/app.js`) and confirmed `agentName` is just a system-prompt template placeholder, not a `task` tool arg. The fallback was dead code; speculative-fallbacks-for-fields-that-might-exist is a maintenance trap.

## What went wrong or was misunderstood

- **Initial fix put SDK arg parsing in the generic event mapper.** The first attempt at "the agent name is missing" added a code path in `agentEventMapper.ts` that special-cased the Copilot SDK's `task` tool args. The user pointed out this file is supposed to be generic across SDKs — SDK-specific shapes belong in the per-SDK adapter (`copilotToolDisplay.ts`). **Prevented by:** new gotcha on `copilot-agent-provider` plus reaffirmed in the new "Subagent rendering" section of `agent-host-session-handler`.
- **First grouping fix landed everything in the parent session.** Attempted to fix grouping by registering inner tool starts the same way as parent tools. That made the UI nest correctly but broke `tool_ready` routing (results landed on the parent session because `tool_ready` lacks `parentToolCallId`). The proper fix was to defer registration. **Prevented by:** new "Subagent rendering" section + gotcha on `agent-host-session-handler`.
- **First UI fix gated both updates on `_isDefaultDescription`.** Looked correct in isolation but silently dropped the late `agentName` because the description had already been set, so the flag was false by the time `subagent_started` arrived. The fix is two independent gated updates. **Prevented by:** the four new "Late metadata updates" tests in `chatSubagentContentPart.test.ts` plus a gotcha on `agent-host-session-handler` describing the failure mode.
- **Speculative `agentName` fallback in `getSubagentMetadata`.** Original code read `args.agentName ?? args.agent_type`. The user asked whether the SDK actually uses both. Investigation showed `agentName` was never emitted; only `agent_type` is destructured. Cargo-culted dead code. **Prevented by:** explicit gotcha on `copilot-agent-provider` saying the SDK has no `agentName` field, don't add a fallback for one.
- **`_pendingSubagentEvents` leaked when parent completed without `subagent_started`.** Caught by Copilot reviewer (comment 5). The buffer was only cleared on drain; if the SDK errored before the child started, the entry stayed forever. Fixed by clearing in `completeSubagentSession` with a regression test. **Prevented by:** gotcha on `agent-host-session-handler` covering the cleanup requirement.
- **Underdocumented testing strategy.** Through this session, four distinct test layers were used (unit, protocol integration, real-SDK integration, workbench/UI) but the docs didn't explain when to use which. The user explicitly called this out at finalize time. **Prevented by:** new `docs/testing.md` covering all four layers with a decision tree and runner commands.

## What we learned

- **The four-layer test strategy.** Unit (in-process, fastest, default), protocol integration (`ScriptedMockAgent` + WebSocket, for protocol-shape behavior), real-SDK integration (`AGENT_HOST_REAL_SDK=1`, for SDK-contract assertions), and workbench/UI (mocked `IAgentConnection`, for content-part rendering). Each one has a sweet spot; reaching for the wrong one wastes time. Documented in the new `docs/testing.md`.
- **Validate regression tests by reverting the fix.** When adding a regression test for a just-fixed bug, briefly revert the fix and confirm the test fails. Did this for the late-metadata-updates suite and caught a gating mistake in the test setup before declaring done. Added to the testing doc as a workflow tip.
- **Keep generic and adapter layers separated even when "just one field" tempts you.** The pull to add SDK-specific knowledge to the generic mapper is real because the mapper is the convenient place to access the event. Resist it. Mappers should forward already-normalized fields; SDK-specific extraction lives in the per-SDK adapter.
- **Independent updates for independently-arriving fields.** When a UI component watches multiple fields that arrive in separate events, each field's update should gate on its own change. Coupling them via "is initial state?" flags creates subtle order-dependent bugs.

## Doc updates

- **New: `docs/testing.md`** — covers the four test layers (unit, protocol integration, real-SDK integration, workbench/UI), runners, when-to-use-which decision tree, workflow gotchas (`unset ELECTRON_RUN_AS_NODE`, retranspile, validate regression tests by reverting). Cross-linked from `index.md` Docs list and from `agent-host-session-handler` Tests section.
- **`docs/agent-host-session-handler.md`** — new "Subagent rendering" section covering inner-`tool_start`-before-`subagent_started` buffering, deferred `_toolCallAgents` registration, independent `description`/`agentName` autorun updates, and parent-without-`subagent_started` cleanup; three new gotchas; expanded Tests section with the new subagent-related test files.
- **`docs/copilot-agent-provider.md`** — new gotcha: SDK-specific arg parsing for the `task` tool (`agent_type`) lives in `getSubagentMetadata`, not in `agentEventMapper`. Removed the `agentName` fallback rationale (the SDK never emits that field). Changelog entry.
- **`index.md`** — added `testing` to the Docs list with a one-line description.
