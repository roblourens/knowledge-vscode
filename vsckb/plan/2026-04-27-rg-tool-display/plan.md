# Plan: Render Copilot CLI rg Tool Calls

Agent Host currently recognizes the older `grep` tool in `copilotToolDisplay.ts`, but Copilot CLI can emit the newer `rg` tool name. Because `rg` is not in `CopilotToolName` or the display switch cases, live and replayed Agent Host sessions fall through to generic messages like `Using "rg"` / `Used "rg"`. Add first-class `rg` rendering in the Copilot SDK adapter, with richer display that includes the search pattern plus useful filters such as `path`, `glob`, `type`, and `output_mode` when present.

## Knowledge context used

- [design-principles](../../docs/design-principles.md) — tool-call display should model the agent-domain behavior in the provider/adapter layer and avoid making clients infer meaning from generic events.
- [agent-host-topology](../../docs/agent-host-topology.md) — confirms tool-call kinds and metadata are one of the narrow sanctioned well-known conventions; `rg` handling belongs in the Copilot provider display normalization, not in protocol clients.
- [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md) — documents `copilotToolDisplay.ts` as the home for SDK tool display normalization, the markdown/localization rules, the extension-host CLI parity reference, and the mirrored present/past-tense requirement.
- [copilot-extension-host-cli](../../docs/copilot-extension-host-cli.md) — establishes `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` as a parity reference while allowing Agent Host to render better when it has better context.
- [testing](../../docs/testing.md) — selects `copilotToolDisplay.test.ts` as the lowest useful test layer for formatter-only changes and requires compile/type-check before test runs.
- [changes/2026-04-22-file-read-line-range](../../changes/2026-04-22-file-read-line-range/summary.md) — recent analogous formatter improvement: add a typed args interface, mirror invocation/past-tense branches, and add focused unit tests.
- [changes/2026-04-24-copilot-skill-tool-display](../../changes/2026-04-24-copilot-skill-tool-display/summary.md) — precedent for translating rather than blindly copying EH-CLI rendering when Agent Host can provide a better user-facing display.
- [changes/2026-04-22-agent-host-cd-cleanup](../../changes/2026-04-22-agent-host-cd-cleanup/summary.md) — reinforces that live and history-replay display paths both consume `copilotToolDisplay.ts`, so formatter changes must naturally cover both.

## Approach

Keep this as a provider-side display normalization fix. The AHP state already carries `toolName`, `displayName`, `invocationMessage`, `pastTenseMessage`, `toolInput`, and `toolArguments`; no protocol/state schema change is needed. The bug is that `rg` is absent from the Copilot provider's known tool enum and switch cases, so the existing live path in `CopilotAgentSession._subscribeToEvents` and replay path in `mapSessionEvents` both receive generic strings from `getToolDisplayName`, `getInvocationMessage`, and `getPastTenseMessage`.

Update `src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` to add `CopilotToolName.Rg = 'rg'` and treat it as a search tool alongside `grep`. Replace the narrow `ICopilotGrepToolArgs` with a shared search args shape that matches the Copilot CLI `rg` schema observed in the extension-host reference: `pattern`, optional `path`, `output_mode`, `glob`, `type`, `-i`, `-A`, `-B`, `-C`, `-n`, `head_limit`, and `multiline`. Only display safe, concise fields: always the pattern; include `path`, `glob`, `type`, and `output_mode` when they are valid non-empty strings; omit booleans and numeric flags from the title unless product wants them later. This avoids a noisy title while still making the common “what did it search and where?” details visible.

Add a small formatter helper in `copilotToolDisplay.ts`, for example `formatSearchDetails(parameters)`, so the `grep` and `rg` invocation/past-tense branches stay mirrored and DRY. The helper should return markdown because the pattern and filters are inline-code spans. Use `appendEscapedMarkdownInlineCode(truncate(...))` for user-controlled values and keep markdown punctuation out of `localize(...)` strings, following the existing `view_range` and grep patterns. `getToolInputString` should treat both `grep` and `rg` the same, returning `pattern` when available and raw JSON otherwise.

Do not add client-side special cases. The existing `mapSessionEvents.ts` and `copilotAgentSession.ts` call sites already pass parsed parameters to the shared formatter and will pick up the display automatically for both replay and live sessions. Permission handling is out of scope because `rg` is not a read-permission request path; if the SDK later asks permission for a search tool, that should be handled as a separate permission-display task.

## Steps

1. Update `src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` to recognize `rg` as a first-class search tool: add the enum member, map its display name to localized “Search”, route invocation and past-tense rendering through the shared search formatter, and update `getToolInputString` to return the pattern for both `grep` and `rg`. — depends on: none
2. Add focused tests in `src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts`: verify `rg` display no longer falls back to `rg`, includes the escaped pattern, includes `path`/`glob`/`type`/`output_mode` details when present, mirrors past-tense wording, and `getToolInputString('rg', ...)` returns the pattern. — depends on: step 1
3. Add or extend a replay-path test in `src/vs/platform/agentHost/test/node/mapSessionEvents.test.ts` only if the unit tests do not already prove the original symptom. The useful assertion would feed a `tool.execution_start` with `toolName: 'rg'` and verify the mapped `tool_start` has `displayName: "Search"` plus a non-generic invocation message. — depends on: step 1; parallel with step 2
4. Validate the change with TypeScript compile check and the focused Agent Host unit tests. — depends on: steps 1 and 2, plus step 3 if added

## Relevant files

- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` — primary formatter: `CopilotToolName`, search args interface, `getToolDisplayName`, `getInvocationMessage`, `getPastTenseMessage`, and `getToolInputString`.
- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/node/copilot/mapSessionEvents.ts` — replay path that already consumes the formatter; likely no code change, possible regression-test surface.
- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` — live path that already consumes the formatter; likely no code change.
- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts` — focused unit tests for display helper behavior.
- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/src/vs/platform/agentHost/test/node/mapSessionEvents.test.ts` — optional replay regression test if desired.
- `/Users/roblou/code/vscode.worktrees/agents-use-the-skill-located-at-vsckb-plan-file-42a739f9/extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` — parity reference: `GrepTool` includes both `grep` and `rg`, with `rg` currently registered under Search.

## Verification

1. Run `npm run compile-check-ts-native` from the VS Code repo root after implementing.
2. Run `unset ELECTRON_RUN_AS_NODE && ./scripts/test.sh --grep "copilotToolDisplay"` for the focused formatter tests.
3. If a `mapSessionEvents` regression test is added, run `unset ELECTRON_RUN_AS_NODE && ./scripts/test.sh --grep "mapSessionEvents"`.
4. Run `npm run valid-layers-check` because the touched files are in the platform layer and should not introduce an invalid import.

## Decisions

- Include richer `rg` rendering, not just minimal `grep` parity. The user selected the richer path; the title should include `pattern` plus concise filters (`path`, `glob`, `type`, `output_mode`) when present.
- Keep the fix in `copilotToolDisplay.ts`; do not add protocol fields or client-side special cases. This is SDK/tool-name normalization at the provider boundary.
- Treat `grep` and `rg` as the same search family for display name, invocation, past tense, and `toolInput`.
- Use markdown messages for search details so code spans render as formatting, not literal backticks.
- Keep numeric/boolean flags out of the title initially. They remain visible in `toolArguments` and can be promoted later if product feedback says the title needs them.

## Risks and open questions

- The actual runtime `rg` schema comes from the Copilot CLI server and can drift from both SDK types and the extension-host reference. Keep parsing defensive: only include fields whose runtime type matches what the formatter expects.
- Long patterns and glob/path filters can make tool titles noisy. Use the existing `truncate(...)` policy and avoid dumping the entire args object into the title.
- `grep` currently has simpler wording. Sharing the richer formatter with `grep` may slightly improve existing `grep` display too; that is acceptable if tests pin the new behavior, but implementation can restrict the extra details to `rg` if preserving `grep` text is preferred.

## Docs that will need updating

- [copilot-sdk-tool-display](../../docs/copilot-sdk-tool-display.md) — add a short note or gotcha that Copilot CLI emits both `grep` and `rg`; Agent Host must normalize both names through the same search formatter, and richer `rg` details should remain defensive and concise.
- No protocol docs should need updates because there is no AHP schema change.
