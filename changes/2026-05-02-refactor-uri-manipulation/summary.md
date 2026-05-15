# Subagent URI refactor and live-streaming routing fixes

**Date:** 2026-05-04
**VS Code branch:** roblou/agents/refactor-uri-manipulation-methods
**VS Code SHA at finalize:** 81095cbaba
**PR:** [#313924](https://github.com/microsoft/vscode/pull/313924)

## What was done

Three related fixes to the Agent Host Copilot provider's subagent handling, landed in a single PR:

**1. URI helpers for subagent sessions** — refactored `parseSubagentSessionUri` and related helpers in `sessionState.ts` to work with real `URI` objects instead of repeatedly round-tripping through `toString()` / `URI.parse()`. The helper now uses a greedy named-capture regex over `resource.path` and returns `parentSession` as a `URI`. Call sites in `agentService.ts`, `copilotAgent.ts`, and `agentConfigurationService.ts` were updated to avoid extra round-trips.

**2. Fix live sync-subagent streaming routing** — sync subagents' text, reasoning, and tool events were routing to the parent session during live streaming. Root cause: `_currentMarkdownPartId` and `_currentReasoningPartId` were single globals, so subagent deltas clobbered the parent session's active part tracker. After the subagent completed, the parent's final `assistant.message` event found no active part to append to and was silently skipped — the final reply only appeared after a nav-away-and-back restore from disk. Fix: replaced both with `Map<string, string>` keyed by `parentToolCallId ?? ''`. Also replaced deprecated `data.parentToolCallId` event routing with event-level `agentId`, populated via `_parentToolCallIdsByAgentId` from `subagent.started`.

**3. Fix nested subagent routing for depth > 1** — two independent bugs that only manifested with depth-2+ nested subagents (subagent spawning a subagent): (a) `onClientToolCallComplete` and `getSessionMessages` stopped after one `parseSubagentSessionUri` call, producing an intermediate URI that is not a key in `_sessions` (keyed by root IDs only), causing completions and message restores to be silently dropped; (b) `_maybeEvictIdleSession` targeted only the immediate parent, leaving root session state cached when only a deeply-nested subagent URI unsubscribed.

## Key decisions

- **Drop events with unmapped `agentId` rather than buffer them.** SDK guarantees `subagent.started` fires before any child `agentId`-tagged events. Initial implementation had complex pre-`subagent.started` buffering helpers (`_pendingSubagentEventHandlersByAgentId`, `_bindSubagentAgentId`, etc.) — user observed these were overly conservative and the SDK ordering guarantee makes them unnecessary.
- **`_sessions` is a root-only map by design.** Only one `CopilotAgentSession` per SDK process exists per root session; subagents run inside that same process under the same session stream. The walk-to-root pattern is the correct resolution for any code that starts from a subagent URI.
- **`URI.with({ path })` not `URI.joinPath()` for subagent paths.** `URI.joinPath` normalizes and can mangle opaque subagent path segments; `URI.with({ path: rawPath })` preserves the exact path text needed for correct prefix matching and round-tripping.

## What went wrong or was misunderstood

- **Used deprecated `data.parentToolCallId` for routing** — initially routed subagent events via `data.parentToolCallId` without realizing it was deprecated. The PR review comment caught it. The SDK deprecates this in favor of event-level `agentId` fields (populated by the SDK at the transport level, not the event payload level). **Prevented by:** gotcha in [copilot-sdk-permissions](../../docs/copilot-sdk-permissions.md#debt--gotchas).
- **Added overly conservative buffering** — built `_withParentToolCallIdForSubagentEvent`, `_bindSubagentAgentId`, and `_pendingSubagentEventHandlersByAgentId` to handle events before `subagent.started`. The SDK guarantees ordering; this was unnecessary complexity. **Prevented by:** the same gotcha noting the SDK ordering guarantee and drop-not-buffer policy.
- **Did not think about nested subagent depth > 1 upfront** — both the `_sessions` lookup and the eviction code assumed depth-1. The `_sessions` root-key invariant was never documented; a code reviewer (Copilot automated review) caught both instances. **Prevented by:** gotcha in [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) and cross-cutting entry in [index.md](../../index.md#active-debt--gotchas).
- **Single-global part IDs were not obviously wrong** — `_currentMarkdownPartId` and `_currentReasoningPartId` looked fine in isolation; the bug only manifested at runtime when a subagent completed and the parent resumed streaming. The symptom (final markdown missing live, present after restore) was surprising because the data was being written to disk correctly — only the live routing was broken. **Prevented by:** gotcha in [copilot-sdk-permissions](../../docs/copilot-sdk-permissions.md#debt--gotchas) explaining the per-subagent Map pattern.

## What we learned

- Copilot automated PR review caught two real depth > 1 bugs that our own analysis missed. The review comments were precise and actionable.
- The symptom of a live-streaming bug (content only appears after nav-away) is characteristic of a part-id clobbering issue: the data is being persisted correctly (restore works), but the live path's active-part tracker has the wrong id.
- The `_sessions` map's root-key-only invariant is a fundamental property of the Copilot provider's architecture (one SDK session per process, all subagents run in the same stream) but was not documented anywhere, making it easy to write bugs like the one-level-up parsing mistake.

## Doc updates

- **`copilot-sdk-permissions.md`**: Added "Subagent event routing" section documenting `_parentToolCallIdsByAgentId`, event-level `agentId` routing, `_shouldDropUnmappedSubagentEvent`, and per-subagent part-ID Maps. Added two gotchas: deprecated `data.parentToolCallId`; Maps must be per-subagent not global.
- **`copilot-agent-provider.md`**: Added two gotchas: `_sessions` root-key invariant with walk-to-root pattern; `_maybeEvictIdleSession` must also walk to root.
- **`index.md`**: Added cross-cutting `_sessions` root-key invariant gotcha under Active debt & gotchas.
