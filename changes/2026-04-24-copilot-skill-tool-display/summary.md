# Render Copilot SDK skill invocations as a tool call

**Date:** 2026-04-25
**VS Code branch:** roblou/agents/copilot-skill-tool-display
**VS Code SHA at finalize:** 89433a4490
**PR:** [#312557](https://github.com/microsoft/vscode/pull/312557)

## What was done

The Copilot SDK exposes a `skill` tool plus a separate `skill.invoked` lifecycle event when the model invokes a skill. The first iteration of this work shipped EH-CLI parity (`Invoking skill: <name>` from the `skill` tool's args). On review we replaced that with a richer, AHP-native rendering:

- **Hide the raw `skill` tool** — added `CopilotToolName.Skill` to `HIDDEN_TOOL_NAMES` so both the live and history-replay paths skip it. Removed the obsolete `case CopilotToolName.Skill:` branches from `getToolDisplayName` / `getInvocationMessage` / `getPastTenseMessage` and the `ICopilotSkillToolArgs` interface.
- **Synthesize a tool-call display from `skill.invoked`** — new `synthesizeSkillToolEvents(session, data, eventId)` and `getSkillSyntheticToolCallId` helpers in `copilotToolDisplay.ts`. Emits a `tool_start` + `tool_complete` pair from one helper consumed by both the live path (`copilotAgentSession._subscribeToEvents`) and the history-replay path (`mapSessionEvents.ts`), per the live-vs-replay mirroring rule. The display uses the **skill name** as the link label (not `SKILL.md`), and `displayName: "Read Skill"`.
- **Filter SDK-injected synthetic user messages** — added `source?: string` to `ISessionEventMessage.data` and `isSyntheticUserMessage(e)` predicate in `mapSessionEvents.ts`; replay skips events with `source && source.toLowerCase() !== 'user'`. Live filtering turned out unnecessary: neither `wrapper.onUserMessage` registration in `copilotAgentSession.ts` actually fires session-progress for user turns.
- **Client-side SKILL.md → skill-pill upgrade** — in `stateToProgressAdapter.ts::rewriteLinkTokenRaw`, detect basename `SKILL.md` (case-insensitive, via `isSkillFileUri`) and tag the rewritten URI with `?vscodeLinkType=skill` while preserving the link label. The chat inline anchor widget keys off the `vscodeLinkType` query parameter to render a rich pill labelled with the skill name. Detection lives client-side, deliberately, so no VS Code-specific link metadata leaks into AHP.
- **New `escapeMarkdownLinkLabel` helper** in `vs/base/common/htmlContent.ts`, escaping only `\` and `]`. Used by both the agent-host skill-link builder and the client-side link rewriter. The pre-existing `escapeMarkdownSyntaxTokens` is too aggressive for renderers that extract the link text without re-parsing markdown — it leaks visible `\-`, `\.`, etc. into the pill label.
- **Hash-based fallback toolCallId** — `getSkillSyntheticToolCallId` hashes its path/name fallback so the synthesized id never embeds `/`, which would break `ChatResponseResource.createUri(..., toolCallId, ...)`'s `/tool/${toolCallId}/${index}` paths.

## Key decisions

- **Hide the `skill` tool entirely instead of formatting its args.** It carries nothing the user cares about that's not also on `skill.invoked`. Fewer duplicate UI rows.
- **Synthesize tool events from `skill.invoked` rather than introducing a new AHP event kind.** Tool-call rendering already supports markdown invocation messages and is uniformly handled by every client. Trades a tiny convention (synthetic `toolCallId`) for protocol simplicity.
- **One helper for live and replay paths.** Existing doc gotcha: divergence between `mapSessionEvents.ts` and `copilotAgentSession.ts` is a known foot-gun.
- **Skill-pill detection is client-side, not protocol-level.** "This file is a SKILL.md → render as a pill" is a VS Code rendering choice, not protocol contract. Keeping it in `stateToProgressAdapter.ts` (next to the existing `vscode-agent-host://` URI rewrite) means other clients (or future Agent Host providers) automatically benefit without protocol churn.
- **Link label uses skill name, not basename.** Every skill file is named `SKILL.md`. `Reading skill [plan]` reads better than the always-identical `Reading skill [SKILL.md]`.
- **`escapeMarkdownLinkLabel` as a sibling helper, not a parameter on `escapeMarkdownSyntaxTokens`.** Two distinct contexts (full markdown body vs. just-the-label-of-a-link) deserve two named helpers; the broader function name + a "what to escape" parameter would invite the same misuse.
- **Filter on `source`, accept legacy leakage.** Sessions persisted before the SDK started setting `source` will still emit stray skill-content user turns. We document this rather than try to detect skill content heuristically.

## What went wrong or was misunderstood

- **Started by copying EH-CLI parity** (`formatSkillInvocation` from `copilotCLITools.ts`), which renders a name-only string. Iteration 1 shipped that and was rejected on review. The EH CLI only sees the `skill` tool args; it can't link to the skill file. Agent Host has direct access to `skill.invoked` and can do better. — **prevented by:** new "Skill events" section in [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md) plus a parity-divergence note in [copilot-extension-host-cli](../../docs/copilot-extension-host-cli.md).
- **Used `escapeMarkdownSyntaxTokens` to escape the link label.** Looked right ("escape markdown chars in agent-controlled data"), but `escapeMarkdownSyntaxTokens` escapes `*_-.~+!{}()` as well, and the chat skill-pill renderer extracts the link text without re-parsing markdown — the escapes leak through as visible `heap\-snapshot\-analysis`. — **prevented by:** new `escapeMarkdownLinkLabel` helper + gotcha on [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md#debt--gotchas) telling future authors which escape to use for link labels vs. full markdown.
- **Embedded the raw filesystem path in the synthesized `toolCallId` fallback.** Worked locally; broke `ChatResponseResource.createUri(..., toolCallId, ...)` in the wider chat pipeline because `/` ends up parsed as a path separator in `/tool/${toolCallId}/${index}`. Caught by the Copilot review. — **prevented by:** new gotcha on [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md#debt--gotchas) about synthetic toolCallIds and `ChatResponseResource.createUri`.
- **Stale local `out/` masked a CI failure.** Local snapshot tests passed against an `out/` that didn't have my latest source. CI built fresh and caught the mismatch. The real cause was that `node test/unit/node/index.js` does NOT retranspile, only `./scripts/test.sh` does, and `npm run compile-check-ts-native` only type-checks (no emit). — **prevented by:** updated workflow tip in [testing](../../docs/testing.md#workflow-tips).
- **Initially tried to apply `?vscodeLinkType=skill` inside the agent host.** Felt wrong — too VS Code-specific to belong in the protocol layer. User pushed back; moved the tagging to the client-side `stateToProgressAdapter.ts` where the existing `vscode-agent-host://` rewrite already lives. — **prevented by:** new gotcha on [agent-host-session-handler](../../docs/agent-host-session-handler.md#debt--gotchas) calling out that "render this kind of link as a rich pill" recognizers belong client-side, with `?vscodeLinkType=…` URI tagging as the convention.
- **Plan task 5 (live-path synthetic-message filter) was based on a wrong reading.** Both `wrapper.onUserMessage` registrations in `copilotAgentSession.ts` only trace-log; neither emits a session-progress event. Filtering only on the history-replay path is sufficient. Cost a small detour. — **prevented by:** the "Skill events" doc section now states this explicitly so the next person doesn't add a redundant live filter.

## What we learned

- **`?vscodeLinkType=…` is the right seam** for "this URI deserves a special widget" decisions. Already in use elsewhere in the chat renderer; reusing it here means we get the rich pill for free without any contribution registration.
- **Two-place mirror rule keeps biting.** `mapSessionEvents.ts` (replay) and `copilotAgentSession.ts` (live) needing to render identically is the load-bearing contract for this whole subsystem. Every change here must consider both. The shared `synthesizeSkillToolEvents` helper is the right shape — leave it as the convention for future synthetic-tool events.
- **Copilot's review was useful.** Three substantive comments (label escaping, fallback id encoding, label injection on the rewriter), all real. Two of them caught defects the test suite did not.

## Doc updates

- [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md):
  - **Added** "Skill events" section covering hide + synthesize + synthetic-user-message filter, with the canonical helper signature and the live-vs-replay one-helper rule.
  - **Trimmed** the specialized-tools `debt:` bullet — `skill` is no longer in the list.
  - **Added** three gotchas: synthetic toolCallIds must not embed paths (use hash); link labels need `escapeMarkdownLinkLabel`, not `escapeMarkdownSyntaxTokens`; SDK only sometimes injects a `user.message` for skills, legacy sessions leak; `_subscribeToEvents` vs `_subscribeForLogging` split.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md):
  - **Added** SKILL.md client-side exception paragraph in "Remote file links in tool messages".
  - **Added** gotcha for the `isSkillFileUri` + `?vscodeLinkType=skill` pattern as the convention for future "render as rich pill" recognizers.
- [copilot-extension-host-cli](../../docs/copilot-extension-host-cli.md):
  - **Added** parity-divergence paragraph to "Parity gaps relevant to Agent Host" calling out skill display as the canonical "translate, don't copy" example.
- [testing](../../docs/testing.md):
  - **Updated** the retranspile workflow tip to clarify that `node test/unit/node/index.js` does not retranspile and `npm run compile-check-ts-native` doesn't emit, so direct unit-runner invocations can give stale-but-green results that CI catches.
