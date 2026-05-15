# Fix live-path reasoning bunching in agentEventMapper

**Date:** 2026-04-28
**VS Code branch:** roblou/agents/agent-session-reasoning-issue
**VS Code SHA at finalize:** 22c8ec60f5
**PR:** https://github.com/microsoft/vscode/pull/313129

## What was done

Fixed an intermittent bug where reasoning text rendered bunched at the top of a restored agent session response instead of interleaved with tool calls. In `src/vs/platform/agentHost/node/agentEventMapper.ts`, the `tool_start` case was clearing `_currentMarkdownPartId` but not `_currentReasoningPartId`. Because the Copilot SDK emits multiple rounds of (reasoning → message → tool calls) within a single chat turn, every later round's reasoning was getting routed to the first reasoning ResponsePart via `SessionReasoning` (which appends content to the existing part). On warm session restore (state still in `_stateManager`), all reasoning rendered as one block sitting before any `ToolCall`. Cold restore went through `_buildTurnsFromMessages` and got the order right thanks to PR #312559, which is why the bug looked intermittent.

Added two failing tests (`reasoning event after tool_start creates a fresh responsePart`, `reasoning event after tool_complete creates a fresh responsePart`) before the fix to lock in the contract.

## Key decisions

- **Match the existing markdown reset pattern** rather than introducing a new state-tracking layer. The fix is one line: `this._currentReasoningPartId.delete(session)` next to the existing markdown delete.
- **Did not also clear on `tool_complete`.** A reasoning event after `tool_complete` and before another `tool_start` (i.e. mid-round) is a hypothetical case; the SDK pattern in real `events.jsonl` always shows `tool_start` arriving next. The added test confirms `tool_complete` also resets, but only because `tool_start` does (the second test reuses the same handler ordering). If a future SDK change emits reasoning between `tool_complete` and the next `tool_start` without a `tool_start` in between, this would need revisiting.
- **Doc lives on `copilot-sdk-tool-display.md`** rather than a new doc, because the corresponding history-replay rule was already documented there. Added `agentEventMapper.ts` to that doc's `Covers:` and renamed the section to "Reasoning ordering: live and history-replay paths" to reflect the symmetry.

## What went wrong or was misunderstood

- **The previous PR (#312559, 2026-04-25) only fixed the cold-restore path.** Its summary correctly noted "Live streaming and history replay are independent code paths for reasoning … keep them consistent when the ordering contract changes," but it didn't follow through and audit `agentEventMapper.ts` for the symmetric requirement, and it didn't leave a `gotcha:` on the live-path code itself. Result: the live-path bug stayed undiscovered until a user noticed sessions sometimes rendering bunched. — **prevented by:** new `gotcha:` on `agentEventMapper.ts:tool_start` in `copilot-sdk-tool-display.md`, plus the renamed/expanded doc section that now describes both paths together rather than only the replay path.
- **The "intermittent" symptom obscured the root cause.** Initial framing ("sometimes I see all the reasoning at the top") sounded like a render-time race. It was actually deterministic: warm restores always bunch, cold restores never bunch. The dependency on whether `_stateManager` still had the session was the key insight. — **prevented by:** the expanded doc section now explicitly calls out "warm vs cold split" so the next person tracing a similar symptom knows to check both paths.

## What we learned

- The "live mapper updates in-memory state" / "history replay rebuilds from raw SDK events" duality is a recurring source of asymmetry bugs in the Agent Host. The same pattern previously bit shell-command rewriting (`stripRedundantCdPrefix` had to be applied on both paths). Worth watching for when reviewing any code that touches `ResponsePart` construction.
- `SessionReasoning` reducer's append-by-id behavior is load-bearing for streaming (deltas need to coalesce) but creates a sharp edge when the part-id tracking is wrong: instead of crashing or mis-rendering visibly, the wrong reasoning silently lands in the wrong slot.
- `./scripts/test.sh` requires `unset ELECTRON_RUN_AS_NODE` first, otherwise `app.setPath` crashes. Worth a one-liner in a workflow doc someday.

## Doc updates

- `docs/copilot-sdk-tool-display.md`:
  - Added `src/vs/platform/agentHost/node/agentEventMapper.ts` and its test to `Covers:`.
  - Renamed "History replay and reasoning order" → "Reasoning ordering: live and history-replay paths". Expanded to describe both paths and the warm-vs-cold restore split.
  - Added `gotcha:` (2026-04-28, agentEventMapper.ts:tool_start case) about clearing both part IDs.
  - Added 2026-04-28 changelog entry.
