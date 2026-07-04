# Route Copilot skill invocations to subagent chats

**Date:** 2026-07-04
**VS Code branch:** agents/remove-skill-invoked-event-handler
**VS Code SHA at finalize:** 3a9278fc17
**PR:** [#324272](https://github.com/microsoft/vscode/pull/324272)

## What was done

Fixed the live Copilot `skill.invoked` path so a skill loaded by a subagent renders in that subagent's chat rather than in the top-level chat. `CopilotAgentSession` now applies the same event-level `agentId` routing used by other child events: it drops unknown subagent IDs, resolves the mapped parent tool-call ID, and threads that scope through the synthesized start, ready, and complete actions.

Added a focused live-session regression test that asserts all three synthesized actions carry the subagent scope and retain the rich clickable link to the resolved `SKILL.md` path. Filed [#324271](https://github.com/microsoft/vscode/issues/324271) for the original symptom and merged the fix in [#324272](https://github.com/microsoft/vscode/pull/324272).

## Key decisions

- **Keep `skill.invoked`.** The ordinary `skill` tool now emits a reliable normal lifecycle, including inside subagents, but its arguments contain only the skill name. The separate lifecycle event is still required because it uniquely carries the resolved `SKILL.md` path used by the linked skill display.
- **Reuse event-level subagent routing.** `skill.invoked.agentId` goes through `_shouldDropUnmappedSubagentEvent` and `_parentToolCallIdForSubagentEvent`, exactly like other child SDK events. No new map or protocol field was needed.
- **Keep the synthetic lifecycle independent from the raw tool lifecycle.** Joining by skill name would be ambiguous for repeated or concurrent invocations. Recent logs showed `skill.invoked.parentId` consistently referenced the preceding skill completion event, but joining on that relationship would require delaying completion or changing completed-tool reducer semantics for no product benefit.
- **Route all three actions together.** Start, ready, and complete must carry the same `parentToolCallId`; splitting their scopes would leave transitions targeting a chat without the matching tool-call state.

## What went wrong or was misunderstood

- **Initially concluded that `skill.invoked` could be removed because the normal `skill` tool lifecycle is now complete.** That was true for lifecycle visibility but ignored the unique resolved path, despite the existing skill-event doc already describing why Agent Host used the separate event. — **prevented by:** strengthened the [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md) body and its `skill.invoked` gotcha to state explicitly that reliable normal tool events are not a replacement for the path-bearing lifecycle event.
- **Considered joining the path back to the normal tool call through a skill-name map.** Names are not safe correlation keys for repeated/concurrent invocations, and mutating an already-completed tool would require additional reducer or timing machinery. — **prevented by:** the routing and lifecycle rationale now recorded in the skill-event doc and this summary.
- **The live/replay asymmetry was missed when the original skill display was added.** History replay already resolved `skill.invoked.agentId`; the live handler synthesized three unscoped actions. — **prevented by:** added the skill-specific routing paragraph and gotcha to [copilot-sdk-permissions](../../docs/copilot-sdk-permissions.md), plus regression coverage over all three live actions.
- **The PR initially retained its exploratory “remove `skill.invoked`” title and description after the implementation changed direction.** Review correctly pointed out that the public history contradicted the code; the title and body were corrected before merge. — **prevented by:** this summary records the pivot; future PR metadata should be rewritten when exploration changes the chosen solution.
- **The first test attempts ran before this fresh worktree had dependencies or compiled `out/`.** `npm install` and `compile-client` were needed before the node runner could load the changed tests. — **prevented by:** the existing [testing](../../docs/testing.md#workflow-tips) guidance already covers fresh/stale `out/`; it should be consulted before the first test command.

## What we learned

- Across the sampled recent logs, every inspected `skill.invoked` event correlated exactly to a preceding normal `skill` completion, including matching agent ID and skill name. That relationship is useful diagnostic evidence, but it is provider behavior rather than a contract worth building a second correlation layer around.
- Event-level `agentId` is the common routing seam even for lifecycle events that synthesize multiple AHP actions. The implementation should resolve scope once and apply it consistently to the whole synthetic sequence.
- A focused snapshot-style test of emitted action envelopes catches both the user-visible placement bug and accidental loss of the linked path.

## Doc updates

- [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md) — clarified why `skill.invoked` remains required, documented live/replay subagent routing, corrected the current synthesis helper name/shape, expanded `Covers:`, and updated the existing skill-event gotcha.
- [copilot-sdk-permissions](../../docs/copilot-sdk-permissions.md) — documented multi-action lifecycle routing and added a `gotcha:` for preserving the same resolved subagent scope across all synthesized skill actions.
- [index](../../index.md) — expanded the tool-display entry's scope and keywords for skill subagent attribution.
- No debt entries were added or removed.
