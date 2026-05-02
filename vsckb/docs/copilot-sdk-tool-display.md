# Copilot SDK Tool Display

_Covers: src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts, src/vs/platform/agentHost/node/copilot/mapSessionEvents.ts, src/vs/platform/agentHost/common/commandLineHelpers.ts, src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts, src/vs/platform/agentHost/test/common/commandLineHelpers.test.ts, extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts_

`copilotToolDisplay.ts` normalizes Copilot SDK tool calls into the generic display fields (`displayName`, `invocationMessage`, `pastTenseMessage`, `confirmationTitle`) that flow through AHP as `StringOrMarkdown`. `mapSessionEvents.ts` handles history replay of SDK events, while `commandLineHelpers.ts` rewrites shell command display at the AHP boundary.

## Tool display messages

Plain strings are rendered as literal text by the chat UI. Any message containing markdown syntax (backticks for inline code, `[text](uri)` links, etc.) MUST be wrapped with the local `md()` helper so it ships as `{ markdown: ... }`. A bare string with backticks renders the backticks as visible characters.

Two rules when interpolating a runtime value into an inline-code span:

1. Keep markdown punctuation out of the localized string. Put the backticks or other markdown formatting around the `{0}` placeholder outside the `localize(...)` call — translators can accidentally drop or transform punctuation, which silently breaks the markdown.
2. Use `appendEscapedMarkdownInlineCode()` from `vs/base/common/htmlContent` to wrap user-controlled values. Backticks inside an inline code span cannot be backslash-escaped per CommonMark; the helper picks a fence of backticks longer than any run in the content and pads with spaces when needed.

The canonical pattern is:

```ts
md(localize('key', "Searching for {0}", appendEscapedMarkdownInlineCode(truncate(args.pattern, 80))))
```

For markdown file links, `formatPathAsMarkdownLink()` already produces the `[name](uri)` form — those still go through `md(...)`.

When a tool's invocation message needs to surface specific tool args (for example the `view` tool's `view_range`), the canonical parity reference is the Copilot CLI extension's `formatXxxInvocation` helpers in `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts`. The extension renders the same SDK tool calls in the workbench chat UI, so its display is the natural baseline. Beware: the extension is reference, not gospel.

## Shell command display rewriting

Shell commands the model emits often start with a redundant `cd <workingDirectory> && …` prefix even though the SDK already runs the tool in that directory. Agent Host strips that prefix at the AHP boundary so every client sees the simplified command. The SDK / PTY still runs the original verbatim — only display is rewritten.

`src/vs/platform/agentHost/common/commandLineHelpers.ts` exports two helpers:

- **`extractCdPrefix(commandLine, isPowerShell)`** — regex-based parse of `cd <dir> && …`, plus PowerShell variants `cd /d <dir>; …`, `Set-Location <dir>; …`, `Set-Location -Path <dir> && …`. Returns `{ directory, command }` or `undefined`. Surrounding double-quotes around `<dir>` are stripped.
- **`stripRedundantCdPrefix(toolName, parameters, workingDirectory)`** — policy wrapper. Returns `boolean` and mutates `parameters.command` in place when (a) `toolName` is `'bash'` or `'powershell'`, (b) the prefix matches, and (c) the extracted directory equals `workingDirectory`.

Three independent display paths all call `stripRedundantCdPrefix`. Adding a new place that surfaces shell command text to AHP clients should call it too:

1. **History replay** — `mapSessionEvents.ts`'s `tool.execution_start` branch. Mutates `parameters.command`, then re-stringifies into `toolArgs` and `toolInput` so both raw and display forms stay in sync.
2. **Live tool start** — `copilotAgentSession.ts` `wrapper.onToolStart` handler. Mutates the parsed `parameters` object stored in `_activeToolCalls`, then re-stringifies `toolArgs` if the rewrite happened. Because `getPastTenseMessage` in `onToolComplete` looks up `_activeToolCalls.get(callId)?.parameters`, the past-tense message automatically reflects the rewritten command — keep that aliasing intact.
3. **Permission requests** — `copilotToolDisplay.ts` `getPermissionDisplay`. Both the `'shell'` kind (synthesizes a `{ command: fullCommandText }` parameters object, then re-extracts `cleanedCommand`) and the `'custom-tool'` kind (mutates `request.args` directly when the SDK tool is a shell tool).

Path comparison normalizes separators by routing both sides through `URI.file()` (after trimming trailing separators) and comparing via `extUriBiasedIgnorePathCase.isEqual`. Do not fall back to raw `fsPath` string comparison: on Windows `URI.file('/repo/project').fsPath` is `\repo\project` while the model often emits `cd /repo/project && …`, which silently slips past a string compare.

The `pwsh &&`→`;` rewriting and the sandbox/background-detach behavior the workbench has are out of scope here. This helper only handles the redundant `cd` prefix.

## Reasoning ordering: live and history-replay paths

Reasoning text reaches AHP state through **two independent code paths** that must stay symmetric, or reasoning visibly bunches at the wrong place in the response.

**History-replay path.** `mapSessionEvents.ts` converts raw SDK session-history events into `IAgentXxx` event shapes. Each SDK event type (`message`, `tool_start`, `tool_complete`, `tool_call`, etc.) maps 1:1 to a typed event; `reasoningText` on a `message` event is forwarded directly onto `IAgentMessageEvent.reasoningText`. `AgentService._buildTurnsFromMessages` (and `_buildSubagentTurns`) then consumes these mapped events and builds `IAgentTurn` objects with `ResponsePart[]` arrays. For assistant messages, reasoning **must** come before the markdown content in the parts array — that is the order the model streams them live, and the restore path must match. The rule: if `msg.reasoningText` is set, push a `ResponsePartKind.Reasoning` part before the `ResponsePartKind.Markdown` part. The extension-host Copilot CLI applies the same pattern: `reasoningText && parts.push({type:"reasoning",...}); content && parts.push({type:"text",...})`.

**Live path.** `copilotAgentSession.ts` translates streaming SDK events into `IAgentProgressEvent`s as they arrive, while `mapSessionEvents.ts` owns cold history replay. The earlier generic mapper split is gone; Copilot-specific event normalization now lives beside the Copilot adapter so SDK event shapes, tool display metadata, subagent routing, and skill synthesis stay in one provider-owned area. Preserve the live-vs-replay symmetry when changing display order: the live session state and the turns rebuilt by `mapSessionEvents` must produce the same `ResponsePart[]` ordering for reasoning, markdown, tools, and subagent turns.

The "warm vs cold" split matters: `AgentService.restoreSession` short-circuits if the session is already in `_stateManager`. Cold restores (process restart, never-touched sessions) hit the history-replay path; warm restores return the in-memory state built by the live path. Both paths must produce the same ordering, or the same session can render correctly one moment and bunched the next.

## Skill events

The Copilot SDK invokes "skills" (markdown files describing reusable tasks) via a `skill` tool, but the more useful signal is the separate `skill.invoked` lifecycle event that carries `{ name, path, description, ... }`. Agent Host **hides the raw `skill` tool** (via `HIDDEN_TOOL_NAMES`) and **synthesizes** a `tool_start` / `tool_complete` pair from `skill.invoked` instead, so the chat UI shows one clickable file link rather than a name-only tool row.

The synthesis lives in `synthesizeSkillToolEvents(session, data, eventId)` in `copilotToolDisplay.ts`. Both call sites — the live path in `copilotAgentSession.ts::_subscribeToEvents` and the history-replay path in `mapSessionEvents.ts` — go through this one helper, per the live-vs-replay mirroring rule. Display:

- `displayName`: `Read Skill`
- `invocationMessage`: ``md(localize("Reading skill {0}", `[<name>](file:///path/to/SKILL.md)`))``
- `pastTenseMessage`: ``md(localize("Read skill {0}", `[<name>](file:///path/to/SKILL.md)`))``
- `toolCallId`: `synth-skill-${eventId | hash(path | name)}` — never includes raw filesystem path
- `toolKind`: undefined (not terminal/edit/subagent)

Note the link uses the **skill name**, not the file's basename: every skill file is named `SKILL.md`, so `Reading skill [plan]` reads better than the always-identical `Reading skill [SKILL.md]`. The chat client's `stateToProgressAdapter.ts` upgrades this link to a rich skill pill when it detects `SKILL.md` as the basename — see [agent-host-session-handler#remote-file-links-in-tool-messages](./agent-host-session-handler.md#remote-file-links-in-tool-messages).

The SDK also injects synthetic `user.message` events carrying skill content (marked with `source: "skill-<name>"`). These are filtered on history replay by `isSyntheticUserMessage(e)` (`e.type === 'user.message' && !!e.data.source && e.data.source.toLowerCase() !== 'user'`). Live-path filtering turned out to be unnecessary: neither `wrapper.onUserMessage` registration in `copilotAgentSession.ts` actually fires session-progress for user turns.

The extension-host Copilot CLI cannot do this synthesis — it only sees the `skill` tool's args (`{ skill: <name> }`), not the path — so its rendering stops at "Invoking skill: <name>". Agent Host getting more out of the SDK is exactly the kind of "translate, don't copy" call the [design principles](./design-principles.md) endorse. See also [copilot-extension-host-cli](./copilot-extension-host-cli.md).

## Debt & gotchas

- **debt** (2026-04-21, copilotToolDisplay.ts) — specialized Copilot CLI tools such as `exit_plan_mode`, `create_pull_request`, and `update_todo` are not normalized in Agent Host display/result handling. Preserve structured semantics if these SDK tools are expected in Agent Host sessions.
- **debt** (2026-04-22, commandLineHelpers.ts:extractCdPrefix) — the `cd`-prefix extraction regex now exists in **three** copies: Agent Host (`commandLineHelpers.ts`), workbench (`runInTerminalHelpers.ts`), and the extension (`copilotCLITools.ts`). The Agent Host version is the most complete (it includes the quoted-directory variant and PowerShell `Set-Location` / `cd /d` forms); the workbench one is missing the quoted variant. Worth a future consolidation pass into a shared `vs/base/common/` (or `vs/platform/`) helper that all three import.
- **gotcha** (2026-04-18, copilotToolDisplay.ts:getInvocationMessage/getPastTenseMessage) — display messages with markdown formatting must (a) be wrapped with `md(...)` so they ship as `{ markdown: ... }`, (b) keep the markdown punctuation (backticks, brackets) outside the `localize(...)` call so translators cannot break it, and (c) wrap interpolated user-controlled strings with `appendEscapedMarkdownInlineCode` for inline-code spans. A plain `string` return from a `StringOrMarkdown`-typed function renders as literal text.
- **gotcha** (2026-04-19, agentService.ts:IAgentDeltaEvent) — the field is `content`, not `delta`. The event's name makes `delta` a tempting typo; producers and consumers both get this wrong.
- **gotcha** (2026-04-19, updated 2026-05-01, copilotToolDisplay.ts:getSubagentMetadata) — SDK-specific argument parsing (for example extracting `agent_type` from the `task` tool's args) lives here, not in a generic mapper. The SDK's `task` tool destructures `agent_type` (snake_case) — there is no `agentName` field; do not add a fallback for one.
- **gotcha** (2026-04-22, commandLineHelpers.ts:stripRedundantCdPrefix) — shell command text reaches AHP clients through three independent paths: history replay, live tool start, and permission requests. When adding a new shell-command rewrite (or any other display transform), call the shared helper from all three paths or the rewrite will look correct on session reload but be missing during live execution / permission prompts.
- **gotcha** (2026-04-22, commandLineHelpers.ts:stripRedundantCdPrefix) — comparing a path extracted from a model-emitted command line against the session `workingDirectory: URI` MUST go through `URI.file(...)` + `extUriBiasedIgnorePathCase.isEqual`, not raw `fsPath` string comparison. On Windows, raw string comparison silently misses common forward-slash paths.
- **gotcha** (2026-04-22, copilotToolDisplay.ts:getInvocationMessage/getPastTenseMessage) — these two functions come in mirrored pairs. Every per-tool branch in `getInvocationMessage` has a matching branch in `getPastTenseMessage`. When adding or tweaking a display variant, touch both.
- **gotcha** (2026-04-22, copilotToolDisplay.ts) — when adding or changing how a Copilot SDK tool's args are formatted into invocation messages, check the Copilot CLI extension's parallel `formatXxxInvocation` helper in `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` for the parity baseline. The extension has its own bugs: both `formatViewToolInvocation` and `formatShowFileInvocation` silently mishandle the `[N, -1]` EOF sentinel for `view_range`; the Agent Host version is allowed to do better.
- **gotcha** (2026-04-25, mapSessionEvents.ts / IAgentReasoningEvent) — `assistant.reasoning` SDK events exist in the TypeScript types but are not emitted in practice (verified across real `.copilot/session-state/*/events.jsonl` files). Reasoning is always bundled as `reasoningText` on `assistant.message` events. Do not add a separate `assistant.reasoning` handling path — the events will not arrive, the code will silently do nothing, and the type system will compile fine the whole time.
- **gotcha** (2026-04-25, copilotToolDisplay.ts:synthesizeSkillToolEvents/getSkillSyntheticToolCallId) — synthesized tool-call ids for non-tool SDK events (skills, future synthetic events) MUST never embed raw filesystem paths. `ChatResponseResource.createUri(..., toolCallId, ...)` builds `/tool/${toolCallId}/${index}` paths, so a `/` in the id breaks URI parsing downstream. The fallback path in `getSkillSyntheticToolCallId` hashes its seed (`hash(seed).toString(16)`) for this reason; the `eventId` branch is safe because SDK event ids are opaque tokens.
- **gotcha** (2026-04-25, copilotToolDisplay.ts:synthesizeSkillToolEvents) — when a markdown link's label is built from agent-controlled data and rendered by something that extracts the link text without re-parsing markdown (e.g. the chat skill pill / inline anchor widget), use `escapeMarkdownLinkLabel` from `vs/base/common/htmlContent.ts`, NOT the broader `escapeMarkdownSyntaxTokens`. The latter escapes `*_-.~+!{}()` as well, which then leak through as visible backslashes (`heap\-snapshot\-analysis`). `escapeMarkdownLinkLabel` only escapes `\` and `]` — the chars that actually break out of `[label](url)` syntax.
- **gotcha** (2026-04-25, mapSessionEvents.ts / copilotAgentSession.ts) — `skill.invoked` is the reliable signal that a skill was invoked. The SDK only **sometimes** also injects a synthetic `user.message` carrying the skill content — the behavior varies by SDK code path / skill type. Filter synthetic messages on `source && source.toLowerCase() !== 'user'`; sessions persisted before the `source` field existed (and any future SDK code path that omits it) will leak stray skill-content user turns. We accept this rather than detect skill content heuristically.
- **gotcha** (2026-04-25, copilotAgentSession.ts:_subscribeToEvents/_subscribeForLogging) — these two methods are split by intent. Anything that fires `_onDidSessionProgress` belongs in `_subscribeToEvents` (where `session = this.sessionUri` is in scope); pure trace-logging belongs in `_subscribeForLogging`. The skill-event synthesis lives in `_subscribeToEvents` for this reason — moving it back to `_subscribeForLogging` would lose access to `session`.

## Related

- [copilot-agent-provider](./copilot-agent-provider.md) — provider lifecycle and session ownership.
- [copilot-extension-host-cli](./copilot-extension-host-cli.md) — extension-host CLI parity reference.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) — permission callbacks and auto-approval.
- [copilot-sdk-shells](./copilot-sdk-shells.md) — managed shells and shell-tool permission asymmetry.

## Changelog

- **2026-05-01** — b2e6267136 — reconciliation: removed stale generic-mapper coverage after `2a5c152b65b9` dropped that abstraction; current ownership is `copilotAgentSession.ts` live events plus `mapSessionEvents.ts` history replay, with `copilotToolDisplay.test.ts` covering display normalization.
- **2026-04-28** — 22c8ec60f5 — renamed "History replay and reasoning order" → "Reasoning ordering: live and history-replay paths"; documented the live-path symmetry rule for clearing both markdown and reasoning part ids on `tool_start`; added coverage for the live mapper then used at the time; added gotcha for the multi-round reasoning bunching bug.
- **2026-04-25** — 89433a4490 — added "Skill events" section: hide the `skill` tool, synthesize `tool_start`/`tool_complete` pair from `skill.invoked` via `synthesizeSkillToolEvents`, filter synthetic `user.message` injections by `source`. Trimmed `skill` from the specialized-tools debt bullet. Added gotchas: synthetic toolCallIds must not embed raw paths (use `hash` of seed); link labels in markdown for skill-pill-style renderers need the narrower `escapeMarkdownLinkLabel`, not `escapeMarkdownSyntaxTokens`; the SDK only sometimes injects a `user.message` for a skill so legacy sessions leak; `_subscribeToEvents` vs `_subscribeForLogging` split.
- **2026-04-25** — ee4918858d — added "History replay and reasoning order" section; added gotcha for `assistant.reasoning` events never being emitted in practice
- **2026-04-24** — 4b6403a3ab — split tool display, SDK event display mapping, and shell command display rewriting out of the Copilot provider overview
