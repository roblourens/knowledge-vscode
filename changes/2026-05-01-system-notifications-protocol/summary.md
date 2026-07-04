# Render and restore Agent Host system notifications

**Date:** 2026-07-03
**VS Code branch:** agents/system-notification-turn-response
**VS Code SHA at finalize:** eea130a57e
**PR:** [#323382](https://github.com/microsoft/vscode/pull/323382)

## What was done

Completed the VS Code side of Agent Host system-notification support across live turns, idle wake-up turns, active-turn reconnect, persisted SDK history, and chat rendering. Copilot SDK notifications that arrive during a turn now stream as AHP `SystemNotification` response parts; qualifying idle notifications create system-origin turns; passive idle notifications remain ignored.

Added a persistent internal chat `systemNotification` response part and compact checked-row renderer shared with system-initiated request rows. Cold session restore now reconstructs notification placement from persisted root assistant-turn boundaries, and reconnect suppresses duplicates by snapshotting the initial response-part count. The draft PR also gained focused provider, replay, adapter, handler, response-model, and renderer coverage. Tracking issue: [#324274](https://github.com/microsoft/vscode/issues/324274).

## Key decisions

- Model in-turn notifications as durable AHP response parts and idle wake-ups as system-origin turns; do not invent an ephemeral notification command or infer transcript content in the client.
- Use one provider normalization helper for localized text and `startsTurn` policy so live and cold-replay paths agree.
- Render notifications as a native persistent chat content kind rather than `progressMessage`, because progress content is transient once later response content arrives.
- Use `initialResponsePartCount` from the exact reconnect snapshot already rendered. Notification parts lack stable ids, so their response-array position is the appropriate snapshot boundary.
- Use persisted root `assistant.turn_start` / `assistant.turn_end` events for replay classification. `session.idle` exists only on the live stream.
- Keep notifications in full response representation/accessibility text, but exclude them from markdown-only and final-answer copy text.

## What went wrong or was misunderstood

- The initial assumption was that the Copilot provider did not emit notifications during active turns. Live debugging showed the provider was correct and `AgentHostSessionHandler._observeTurn` was dropping the already-created AHP part. — **prevented by:** the new [agent-host-system-notifications](../../docs/agent-host-system-notifications.md) end-to-end path and the `_observeTurn` gotcha in both that doc and [agent-host-session-handler](../../docs/agent-host-session-handler.md).
- A persistence/database-based workaround was briefly built for a live-streaming problem. It addressed the wrong layer and added state bookkeeping instead of forwarding the existing response part. — **prevented by:** the new doc's separation of live ingestion, cold history replay, and editor-window observation.
- The first rendering shape converted notifications to `progressMessage`. Later response content hides transient progress, so the notification still disappeared from the transcript. — **prevented by:** the new doc's chat-content section stating that transcript-visible notifications require a native persistent part.
- Reconnect handling initially grew notification-specific counters. A generic `initialResponsePartCount` from the rendered snapshot is simpler and covers any later appended positional response part without a parallel notification state machine. — **prevented by:** the reconnect section and `initialResponsePartCount` gotcha in the new doc.
- Replay initially looked for a live idle signal, but SDK `session.idle` is absent from persisted `events.jsonl`. Real histories showed that root assistant turn start/end events are the durable boundary. — **prevented by:** the persisted-history section and `mapSessionEvents` gotcha in the new doc.
- A final-response copy branch included `systemNotification`, but the preceding contiguous-markdown scan made that branch unreachable. Copilot review caught it and the dead condition was removed. — **prevented by:** the new doc's explicit copy semantics; notifications belong in full response representation, not final-answer markdown.

## What we learned

- Agent Host response rendering has three separate consumers that must be audited together: completed history, active-turn reconnect hydration, and live observation of newly appended parts.
- Live and cold-restored Copilot sessions need semantic symmetry, but they cannot always use the same raw SDK events; persisted boundaries may differ from live lifecycle signals.
- The launch/debug path was decisive here: observing the provider action arrive before the UI dropped it prevented further changes at the wrong layer.
- This work reinforces existing design principles rather than adding a new one: durable semantics belong in AHP, while VS Code should add an honest native UI shape when generic progress cannot represent them.

## Doc updates

- **Created `docs/agent-host-system-notifications.md`** with live, replay, reconnect, rendering/copy, and test behavior; added three gotchas for persisted turn boundaries, explicit live observation, and positional reconnect suppression.
- **Updated `docs/agent-host-session-handler.md`** with notification ownership, the three-path response rendering rule, test references, a `_observeTurn` gotcha, and a changelog entry.
- **Updated `index.md`** with the new doc and a cross-cutting live/replay symmetry pointer under `## Active debt & gotchas`.
- No debt entries were resolved or removed.
