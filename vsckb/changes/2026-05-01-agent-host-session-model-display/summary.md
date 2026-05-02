# Per-turn model display in agent-host sessions

**Date:** 2026-05-02
**VS Code branch:** roblou/agents/agent-host-session-model-display
**VS Code SHA at finalize:** cb70af8eb9
**PR:** [#313885](https://github.com/microsoft/vscode/pull/313885)

## What was done

Restored agent-host chat sessions now show the model used for each response in the per-message footer, matching extension-host Copilot CLI sessions. `AgentHostSessionHandler` injects `ILanguageModelsService` and builds a `TurnModelLookup` that resolves `Turn.usage?.model` (falling back to `SessionSummary.model?.id`) into both the namespaced chat language-model id (for `request.modelId`) and a human-readable display name (for `response.details`). The lookup is threaded through `turnsToHistory` and the active-turn placeholder request, so reload-during-turn keeps the in-progress request stamped with the same model the completed turns above it show.

## Key decisions

- **Use `Turn.usage?.model` rather than threading a separate `model` field through AHP.** `UsageInfo.model` already exists on every `Turn` and `ActiveTurn` in the protocol — the gap was purely on the consumer side.
- **Per-turn lookup callback, not a precomputed map.** `_createTurnModelLookup` returns `{ toLanguageModelId, toModelDisplayName }`, both of which take a raw model id and apply session-level fallback internally. Keeps `turnsToHistory` and the active-turn restoration call site free of fallback logic.
- **Active-turn placeholder uses the same fallback path.** A reconnect mid-turn renders the request with the resolved model so it doesn't visually drift from completed turns above it. Response is still empty — live progress replays via `activeTurnToProgress`.
- **Did not extract a helper for the active-turn placeholder.** A first iteration extracted `activeTurnToHistoryRequest` and unit-tested it in isolation in response to a Copilot review comment. User feedback: the isolated test isn't interesting; integrated coverage is. Reverted the extraction and added a single integrated test in `agentHostChatContribution.test.ts` (`history loading` suite) that drives `provideChatSessionContent` against a session containing two completed turns (one with `usage.model`, one without) and an `activeTurn`, asserting all three request `modelId`s in one snapshot.
- **Pricing / multiplier badges deferred.** Extension-host Copilot CLI sets `multiplierNumeric`/`pricing` on `ILanguageModelChatMetadata`; `SessionModelInfo` in AHP has no equivalent field, so `AgentHostLanguageModelProvider` can't forward what isn't there. Recorded as debt in the handler doc; would require an AHP protocol change first.

## What went wrong or was misunderstood

- **Initial assumption that AHP had no per-turn model info.** First instinct was to look at `SessionModelInfo` / `SessionSummary.model` and conclude that we'd need a protocol change. The user corrected: "model is on UsageInfo". `Turn.usage?.model` and `ActiveTurn.usage?.model` were already on the protocol, just unused. **Prevented by:** doc body update on `agent-host-session-handler.md` (new "Per-turn model rendering" section explicitly names the AHP fields the handler reads from).
- **First attempt at addressing the Copilot review comment was wrong-shaped.** Extracted a small `activeTurnToHistoryRequest` helper and added isolated unit tests for it. The user's principle: testing a tiny extracted function in isolation is uninteresting — the regression risk is in the handler-side stitching, not the helper. Reverted the extraction and tested `provideChatSessionContent` end-to-end instead. **Prevented by:** this `changes/` summary — it's a workflow lesson (favor integrated tests over isolated unit tests for thin extracted helpers), not something that fits a `gotcha:` on a particular file.

## What we learned

- Per-response `details` is the chat-list contract for the model footer. `chatListRenderer.ts` reads `element.result?.details` and `chatServiceImpl.ts` propagates the history item's `details` to `response.setResult`. Worth knowing for any future "show X next to the response" feature.
- `SessionSummary.model` is the right per-session fallback for old turns that have no `usage.model` — the extension-host CLI does the same conceptually (selected model is the fallback when usage doesn't carry one).
- The screenshot-test CI job (`Checking Component Screenshots`) is unrelated to chat/agent code; failures there for `editor/inlineChatZoneWidget` baselines are not a signal about chat-session changes.

## Doc updates

- `docs/agent-host-session-handler.md`:
  - Added "Per-turn model rendering" section between request-context/client-tool parity and "Where to edit".
  - Added debt entry for missing multiplier/pricing on `SessionModelInfo` (blocks parity with extension-host CLI's pricing badges).
  - Added 2026-05-02 changelog entry.
