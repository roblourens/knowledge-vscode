# Render `view_range` in agent host file-read tool display

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/add-line-range-to-file-read
**VS Code SHA at finalize:** 04236e61bf9
**PR:** [#312062](https://github.com/microsoft/vscode/pull/312062)

## What was done

When the Copilot CLI `view` tool reads a slice of a file (`view_range: [start, end]`), the agent host's tool-call display previously rendered just `Reading <file>`, hiding the line range from the user. The Copilot CLI extension's UI shows the range, so agent-host-backed sessions felt strictly worse for read-heavy tool calls.

Surfaced the range in `src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts`:

- New `ICopilotViewToolArgs extends ICopilotFileToolArgs { view_range?: number[] }`.
- New `formatViewRange` helper that validates the array (length 2, both integers, `startLine >= 0`, and `endLine === -1` || `endLine >= startLine`) and returns either `{ startLine, endLine }` or `undefined`.
- Both `getInvocationMessage` and `getPastTenseMessage` now have three branches in their `view` case:
  - `view_range: [N, -1]` → "Reading {file}, line N to the end" / "Read {file}, line N to the end"
  - `view_range: [N, M]` with `M > N` → "Reading {file}, lines N to M" / "Read {file}, lines N to M"
  - `view_range: [N, N]` (or `[N, M]` with `M === N`) → "Reading {file}, line N" / "Read {file}, line N"
  - Otherwise → existing "Reading {file}" / "Read {file}" (path-only fallback)

Also added five focused tests in `src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts` exercising path-only, lines X-Y, single line, EOF sentinel, and the invalid-range fallbacks for both functions.

No protocol/IPC plumbing was needed: `view_range` was already arriving in the parsed `parameters` object that flows into `getInvocationMessage` / `getPastTenseMessage` from `mapSessionEvents.ts` and the live `wrapper.onToolStart` handler. Only the display formatter needed updating. The SDK's `read` permission request only carries `path` + `intention` (not `view_range`), so `getPermissionDisplay`'s `'read'` branch stays unchanged.

## Key decisions

- **Treat `[N, -1]` as a documented EOF sentinel and render it explicitly.** The Copilot CLI extension's `formatViewToolInvocation` and `formatShowFileInvocation` (in `vscode-copilot-chat/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts`) both mis-handle this case — one drops the range entirely, the other prints `-1` literally. We deliberately diverge from the extension to render "from line N to the end". The agent host display is allowed to do better than the extension here.
- **Validate strictly, fall back silently.** `formatViewRange` returns `undefined` on any malformed shape and the caller falls back to the path-only message. The Copilot model occasionally emits floats, swapped endpoints, single-element arrays, etc., and a fallback is preferable to a misleading "lines 20 to 10". The Copilot reviewer's first comment caught the original lax validation.
- **Mirror present and past tense.** Every new branch added to `getInvocationMessage` is also added to `getPastTenseMessage`. A late wording tweak ("from line N to the end" → "line N to the end") was applied to both functions, not just the present-tense one — the asymmetry was caught during review.
- **Plain `localize` strings without markdown punctuation in the localized text.** The line numbers and file links are interpolated as literal numbers / `[name](uri)` outside the localized format string, so translators can't break the markdown. This is the same pattern documented in the existing tool-display gotcha.

## What went wrong or was misunderstood

- **Didn't think to check the Copilot Chat extension as the parity reference.** First pass came directly from the SDK type definitions for `view_range` and reinvented the rendering. The user had to ask twice ("can you check what the extension does"). The extension's `copilotCLITools.ts` is the canonical sibling for any SDK tool display work — it ships in workbench chat and has had more iteration. **Prevented by:** new `gotcha` on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) saying check `copilotCLITools.ts` first when changing tool display formatters. Also tweaked the "Tool display messages" body section to call this out up front.

- **Initial validation in `formatViewRange` was too lax.** First version accepted non-integer numbers, didn't enforce `endLine >= startLine`, didn't reject negative starts. The Copilot reviewer caught it. Tightened to match the extension's stricter validation, then realized that doing so dropped the `[N, -1]` EOF case entirely (the extension's bug). Re-added the EOF branch as an intentional improvement over the extension. **Prevented by:** the new parity-reference gotcha now explicitly names this trap — "the extension is reference, not gospel."

- **Lost the EOF case when first matching the extension's validation.** Went from "broken (rendered as 'line 10' for `[10, -1]`)" to "worse (rendered as just 'Reading file.ts')" before the user prompted "now what happens if -1 is sent?". This was a foot-gun of "match the reference impl" without checking the cases the reference impl gets wrong. **Prevented by:** the same gotcha as above, plus the new tests pin all four shapes (range, single-line, EOF, invalid) so this can't regress silently.

- **Made a wording tweak in only one of the paired present/past-tense functions.** User noticed "from line N to the end" → "line N to the end" was applied only to `getInvocationMessage` and asked me to mirror it to `getPastTenseMessage`. **Prevented by:** new `gotcha` on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) explicitly noting that `getInvocationMessage` and `getPastTenseMessage` come in mirrored pairs and any change to one needs the parallel change in the other.

- **Told the Copilot reviewer there was no `copilotToolDisplay.test.ts` when there is one.** Replied to a review comment claiming display formatting wasn't covered by unit tests at all — and only later (during finalize) did I find the file with five existing cd-prefix tests. The reviewer's request for tests was not just reasonable but trivially actionable; I should have checked first. Tests are now added in commit `04236e61bf9`. **Prevented by:** general practice — `ls test/node/<file>.test.ts` is one tool call. Don't claim absence without checking.

## Knowledge updates

- [docs/copilot-agent-provider.md](../../docs/copilot-agent-provider.md):
  - Tool display messages section: appended a paragraph naming `vscode-copilot-chat`'s `copilotCLITools.ts` as the parity reference and noting the `[N, -1]` EOF mishandling to watch for.
  - Debt & gotchas: added two new gotchas (parity reference and present/past-tense mirroring).
  - Changelog: new entry for this session pointing here.
