# Fix reasoning render order when restoring agent host sessions

**Date:** 2026-04-25
**VS Code branch:** roblou/agents/fix-agent-session-render-order
**VS Code SHA at finalize:** ee4918858d
**PR:** [#312559](https://github.com/microsoft/vscode/pull/312559)

## What was done

When re-opening an agent host session, all "thinking" (reasoning) text appeared bunched up at the top of the response instead of being properly interspersed with tool calls and markdown content.

Root cause: `AgentService._buildTurnsFromMessages` reconstructed turns from SDK history events without touching `IAgentMessageEvent.reasoningText`. That field was already forwarded by `mapSessionEvents.ts`, but nothing consumed it when rebuilding `ResponsePart[]` arrays on restore. The same bug existed in `_buildSubagentTurns` for subagent inner messages.

Fix: for each assistant message in the history, push a `ResponsePartKind.Reasoning` part from `msg.reasoningText` immediately before the `ResponsePartKind.Markdown` part. This matches the live-streaming order (reasoning deltas arrive via `onReasoning`/`onReasoningDelta` before the message content) and matches the extension-host Copilot CLI's history replay pattern.

Also introduced `SessionHistoryEvent` as a named type alias for the `IAgentMessageEvent | IAgentToolStartEvent | IAgentToolCompleteEvent` union returned by `IAgent.getSessionMessages()`, replacing the verbose inline union across all call sites.

## Key decisions

- Push `Reasoning` before `Markdown` for the same message — not the other way around. This preserves the original model-stream order (reasoning is emitted before reply text).
- Keep the subagent fix symmetric (`_buildSubagentTurns`). Subagent inner messages carry the same `reasoningText` field and would have had the same bunching on restore.
- Use a named `SessionHistoryEvent` type alias rather than repeatedly writing the three-way union. No functional change; the type alias makes call sites readable and future additions (if any) consistent.

## What went wrong or was misunderstood

- **Assumed `assistant.reasoning` events were emitted based on TypeScript types** — `IAgentReasoningEvent` is defined in the SDK types and looked like it would be a separate event stream. A full first implementation was built: added `IAgentReasoningEvent` to `SessionHistoryEvent`, handled it in `mapSessionEvents`, handled it in `_buildTurnsFromMessages`. Rob pointed out these events aren't emitted in practice — reasoning is bundled onto `assistant.message.reasoningText`. The first implementation was reverted and replaced. **Prevented by:** `gotcha` on `copilot-sdk-tool-display.md` (added this session) — `assistant.reasoning` events exist in types but are never emitted; reasoning lives on `assistant.message.reasoningText`.

- **Missed `ScriptedMockAgent` when migrating to `SessionHistoryEvent` alias** — Updated all the main files to use the new alias but missed `ScriptedMockAgent._preExistingMessages` and its `getSessionMessages()` return type. The Copilot PR reviewer caught it. **Prevented by:** when doing a type alias refactor, search for ALL occurrences of the old inline union syntax before declaring done.

## What we learned

- The EH CLI packaged at `~/.copilot/pkg/universal/<version>/app.js` is the most reliable reference for SDK event shapes and the history replay pattern. When there's ambiguity about what the SDK actually emits (vs. what its type definitions say), reading real `~/.copilot/session-state/*/events.jsonl` files is faster than inferring from TypeScript types.
- Live streaming and history replay are independent code paths for reasoning. The live path (`agentEventMapper.ts` via `onReasoning`/`onReasoningDelta`) and the restore path (`_buildTurnsFromMessages` from stored message events) both need explicit reasoning handling, but they don't share code — keep them consistent by checking both when the ordering contract changes.

## Doc updates

- `docs/copilot-sdk-tool-display.md` — added "History replay and reasoning order" section describing how `mapSessionEvents.ts` + `_buildTurnsFromMessages` reconstruct reasoning order on restore. Added gotcha: `assistant.reasoning` events defined in SDK types are never emitted in practice.
