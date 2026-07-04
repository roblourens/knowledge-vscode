# Agent Host system notifications

_Covers: src/vs/platform/agentHost/node/copilot/copilotSystemNotification.ts, src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts, src/vs/platform/agentHost/node/copilot/mapSessionEvents.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/stateToProgressAdapter.ts, src/vs/workbench/contrib/chat/common/model/chatModel.ts, src/vs/workbench/contrib/chat/browser/widget/chatContentParts/chatSystemNotificationContentPart.ts_

System notifications are transcript-visible agent events that can either occur inside an active assistant turn or wake an idle session and start a new turn. AHP models the first form as `ResponsePartKind.SystemNotification` and the second as a turn whose message origin is `MessageKind.SystemNotification`. The distinction is durable protocol state rather than an ephemeral UI notification.

## Copilot SDK normalization

`buildCopilotSystemNotification()` is the single normalization point for SDK `system.notification` events. It turns provider-specific kinds into a concise localized `messageText` plus a `startsTurn` policy:

- shell and background-agent completion/failure events set `startsTurn: true`;
- inbox and instruction-discovery events are passive (`startsTurn: false`);
- unsupported or empty events return `undefined`.

Both live ingestion and cold history replay call this helper. Keep the user-visible text and the turn-start policy centralized here so warm and restored sessions cannot diverge.

## Live event semantics

`CopilotAgentSession._subscribeToEvents` handles three cases:

1. **Active turn:** if `_turnId` exists, dispatch `ActionType.ChatResponsePart` with `ResponsePartKind.SystemNotification`. The notification remains in the current response at the SDK stream position.
2. **Idle, turn-starting notification:** create a new turn with `origin.kind === MessageKind.SystemNotification`. This is rendered as a system-initiated request row.
3. **Idle, passive notification:** ignore it. There is no current response to attach it to and its policy does not justify creating a new turn.

This provider path only gets the event into AHP state. The editor-window handler must separately observe the new response part for it to stream into an already-open chat.

## Persisted history replay

`mapSessionEvents()` reconstructs the same three semantics from SDK `events.jsonl`. SDK `session.idle` is ephemeral and is not stored, so replay cannot use it to decide whether a notification occurred during a turn. Persisted root `assistant.turn_start` and `assistant.turn_end` events are the boundary:

- between root `assistant.turn_start` and `assistant.turn_end`, append the notification to the current parent turn as a `SystemNotification` response part;
- outside that boundary, a `startsTurn` notification flushes the previous turn and creates a system-origin parent turn;
- outside that boundary, a passive notification is ignored;
- a root `abort` also clears the active-assistant-turn flag.

Only root assistant boundaries participate. Subagent assistant boundaries carry `agentId` and must not change the parent turn's notification classification.

## Editor-window adaptation and reconnect

`stateToProgressAdapter.ts` converts `ResponsePartKind.SystemNotification` to the internal persistent chat kind `{ kind: 'systemNotification', content }`. The same conversion is used by:

- `turnsToHistory()` for completed/restored turns;
- `activeTurnToProgress()` for the initial active-turn reconnect snapshot;
- `AgentHostSessionHandler._observeTurn()` for parts appended after live observation begins.

These are independent paths. Implementing history and reconnect conversion does not make live streaming work; `_observeTurn` must explicitly handle the response-part kind.

On reconnect, the handler captures `initialResponsePartCount` from the same `activeTurn` snapshot passed to `activeTurnToProgress()`. The live observer only emits later system-notification parts whose array index is at or beyond that boundary. This suppresses duplicate rendering without notification-specific counters. `SystemNotificationResponsePart` has no stable id, so array position is intentionally the identity available for this snapshot boundary.

## Chat content and rendering

System notifications use a native persistent chat response part, not `progressMessage`. Progress messages are transient and can disappear when later non-progress content arrives, which makes them unsuitable for transcript content.

`ChatSystemNotificationContentPart` renders the notification through `ChatProgressSubPart` with `Codicon.check`. `chatListRenderer.ts` reuses the same compact checked-row renderer for system-initiated request rows, so embedded and turn-starting notifications share a presentation while retaining different transcript structure.

The part remains in the response model and serialized operation log. `Response.toString()` includes it as a standalone block for full response representation/accessibility, while `getMarkdown()` and `getFinalResponse()` exclude it because it is not assistant markdown and should not be copied as the final prose answer.

## Tests

The behavior is intentionally split across layers:

- `src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts` — live active-turn and idle notification policy;
- `src/vs/platform/agentHost/test/node/mapSessionEvents.test.ts` — persisted in-turn, turn-starting, and passive-outside-turn replay;
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/stateToProgressAdapter.test.ts` — AHP-to-chat part conversion;
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostChatContribution.test.ts` — live handler streaming and reconnect duplicate suppression;
- `src/vs/workbench/contrib/chat/test/browser/widget/chatContentParts/chatSystemNotificationContentPart.test.ts` — persistent checked-row rendering;
- `src/vs/workbench/contrib/chat/test/common/model/chatModel.test.ts` — response-part persistence and text representation.

See [testing](./testing.md) for runner guidance and the broader test-layer decision tree.

## Related

- [agent-host-session-handler](./agent-host-session-handler.md) — shared AHP-to-chat handler and active-turn observation.
- [agent-host-protocol](./agent-host-protocol.md) — AHP turn and response-part state.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — another provider area with the same live/history symmetry requirement.

## Debt & gotchas

- **gotcha** (2026-07-03, mapSessionEvents.ts:mapSessionEvents) — SDK `session.idle` is not persisted. Cold replay must classify notifications with root `assistant.turn_start` / `assistant.turn_end` boundaries and clear the flag on root abort; using live-only idle state makes restored sessions diverge.
- **gotcha** (2026-07-03, agentHostSessionHandler.ts:_observeTurn) — history (`turnsToHistory`) and reconnect (`activeTurnToProgress`) adapters do not stream newly appended response parts. Every transcript-visible response kind needs an explicit `_observeTurn` branch.
- **gotcha** (2026-07-03, agentHostSessionHandler.ts:initialResponsePartCount) — reconnect duplicate suppression uses the response-array length from the exact active-turn snapshot already rendered. System-notification parts have no stable id; do not replace this with notification-specific counters or derive the boundary from a later state read.

## Changelog

- **2026-07-03** — eea130a57e — initial entry documenting live, replay, reconnect, persistent rendering, copy semantics, and test coverage for Agent Host system notifications.
