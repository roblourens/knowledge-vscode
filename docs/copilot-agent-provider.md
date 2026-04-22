# Copilot Agent Provider

_Covers: src/vs/platform/agentHost/node/copilot/copilotAgent.ts, src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts, src/vs/platform/agentHost/node/copilot/copilotShellTools.ts, src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts, src/vs/platform/agentHost/node/copilot/mapSessionEvents.ts, src/vs/platform/agentHost/common/commandLineHelpers.ts, src/vs/platform/agentHost/test/node/copilotAgent.test.ts, src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts, src/vs/platform/agentHost/test/node/copilotShellTools.test.ts, src/vs/platform/agentHost/test/node/copilotToolDisplay.test.ts, src/vs/platform/agentHost/test/node/mapSessionEvents.test.ts, src/vs/platform/agentHost/test/common/commandLineHelpers.test.ts_

`CopilotAgent` is the local Agent Host provider backed by the Copilot SDK. It is provider-specific code under `src/vs/platform/agentHost/node/copilot/`, below the generic AHP server layer and above the SDK runtime. Generic aggregation (`AgentService`) and UI consumers should receive already-filtered Copilot session metadata from this provider.

## Responsibilities

`CopilotAgent` owns:

- Starting and stopping the SDK `CopilotClient`, including the clean subprocess environment used for the CLI server.
- Advertising Copilot models and protected resources.
- Creating, forking, resuming, listing, disposing, aborting, truncating, and changing model selection for Copilot sessions.
- Building SDK session config from active client tools, customizations, hooks, MCP servers, custom agents, skills, and shell tools.
- Persisting provider-local metadata in the per-session Agent Host database.

It does not own AHP state shape or workbench rendering. Contract changes belong in [agent-host-protocol](./agent-host-protocol.md); turn execution and rendering belong in [agent-host-session-handler](./agent-host-session-handler.md).

## Authentication contract

`listSessions()` and `_listModels()` both go through `_ensureClient()`, which throws `ProtocolError(AHP_AUTH_REQUIRED, ...)` when `_githubToken` is unset. This is required by the AHP spec — Copilot's `protectedResources` declares `required: true`, which the [authentication spec](https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/authentication.md) mandates the server return `AuthRequired` (-32007) for, not silently respond with empty data. `_refreshModels()` is the only caller that swallows the throw (it guards on `!_githubToken` first and catches errors), because the models observable has no other natural retry path; everything else relies on the renderer-side `authenticationPending` autorun in [`LocalAgentHostSessionsProvider`](./agent-host-sessions-providers.md#one-shot-_ensuresessioncache--auth-aware-eager-load) to drive the retry.

Returning `[]` instead of throwing was a real bug: it caused the Agents-app sidebar to never display sessions on a fresh launch (the renderer's one-shot cache held the empty response forever; only `notify/sessionAdded` from the user's first message broke the deadlock). See [changes/2026-04-20-fix-initial-session-list-display](../changes/2026-04-20-fix-initial-session-list-display/summary.md).

## Session Ownership

The Copilot SDK can list sessions that were created outside VS Code's Agent Host, such as sessions from other Copilot CLI agents. `CopilotAgent.listSessions()` is responsible for filtering SDK results down to sessions that VS Code Agent Host owns or has already adopted.

The ownership signal is the existence of a per-session Agent Host database. `listSessions()` constructs the canonical `AgentSession.uri('copilotcli', sessionId)` for each SDK result and calls `ISessionDataService.tryOpenDatabase()`. If no database exists, the SDK session is skipped. This check must happen before project resolution or any metadata write so listing does not create databases for unrelated SDK sessions.

> **`CopilotAgent.id` is `'copilotcli'`.** It used to be `'copilot'`; renamed in the [2026-04-20 session-routing change](../changes/2026-04-20-remote-agent-session-routing-fix/summary.md) to align the agent's advertised provider name with the UI session-type id (was previously bridged through a now-deleted `WELL_KNOWN_AGENT_SESSION_TYPES` alias map). The on-disk per-session DB key derives from the raw session id (`AgentSession.id(uri) = uri.path.substring(1)`), **not** the URI scheme, so the rename does not invalidate stored databases — old `copilot:///<sid>` URIs and new `copilotcli:///<sid>` URIs hit the same DB row.

Any existing per-session database qualifies as owned. This intentionally keeps the rule simple: sessions created by Agent Host already create a database when metadata is stored, and older sessions with database metadata continue to appear. The implementation does not persist a separate Copilot ownership marker.

After a session passes the database gate, `listSessions()` may resolve project metadata and store the resolution to avoid rediscovering git context on later lists. That write is safe because the database already existed before the list operation considered the session owned.

This database-existence gate is the local-agent-host half of the coexistence contract with the extension-host `CopilotChatSessionsProvider`. The extension provider has its own symmetric filter via `IChatSessionMetadataStore.getSessionOrigin()` — sessions without the extension's per-session JSON metadata return `'other'` and are excluded. Together these two filters ensure each provider shows only its own sessions with no overlap. See [agent-host-sessions-providers § Coexistence](./agent-host-sessions-providers.md#coexistence-with-the-extension-host-provider).

## Metadata

Copilot provider metadata is stored in the session database's `session_metadata` table. Current keys include:

- `copilot.model` — serialized `IModelSelection`, including model config such as reasoning effort.
- `copilot.workingDirectory` — URI string for the session working directory.
- `copilot.project.resolved` — marker that project resolution was attempted.
- `copilot.project.uri` and `copilot.project.displayName` — cached project identity for list metadata.
- `copilot.worktree.branchName` — set when isolation is `worktree`. Used by the restore path of the [session announcements](#session-announcements-worktree-creation) feature to reconstruct the "Created isolated worktree for branch X" message when a session is reopened.

Use `tryOpenDatabase()` for read-only checks that must not create session data. Use `openDatabase()` only on paths that intentionally create or update Agent Host-owned session data.

## Session announcements (worktree creation)

When `_resolveSessionWorkingDirectory` creates an isolated worktree, the user should see a "Created isolated worktree for branch `X`" message at the top of the very first response — both live as the model is replying, and on every subsequent reopen of the session.

The message is plain markdown, so it's surfaced through the existing AHP delta channel rather than a dedicated event type. There are two paths and they're independent:

1. **Live path (first turn only).** `_resolveSessionWorkingDirectory` populates `_pendingFirstTurnAnnouncements: Map<sessionId, string>` with the rendered markdown. The first call to `sendMessage` for that session drains the entry (one-shot `get` + `delete`) and fires a synthetic `IAgentDeltaEvent` whose `messageId` is `copilot-announcement-<uuid>` *before* delegating to the SDK. The session-handler mapper appends the SDK's subsequent deltas to the same markdown part, so the announcement and the model's reply render as one continuous markdown block.

2. **Restore path (every reopen, including across process restarts).** `getSessionMessages` reads `copilot.worktree.branchName` via `tryOpenDatabase()` and calls the local `prependAnnouncementToFirstAssistantMessage(messages, text)` helper. It walks the message list and prepends the announcement to the **first top-level assistant message** — `m.type === 'message' && m.role === 'assistant' && !m.parentToolCallId`. Subagent inner messages are skipped on purpose so the announcement lands on the parent turn, not buried inside a subagent's history. If no top-level assistant message exists yet, the messages are returned unchanged — the live path is the only thing that fires before any reply has been recorded, and the announcement is acceptable to lose if the agent process restarts in that narrow window.

The announcement text is built by the local `buildWorktreeAnnouncementText(branchName)` — a `localize(...)` call that wraps `branchName` with `appendEscapedMarkdownInlineCode(...)` (see [tool display messages](#tool-display-messages) for the same rule applied to tool messages) and ends with `'\n\n'` so it visually separates from whatever follows when concatenated.

The `IAgentDeltaEvent` field is `content`, not `delta` — easy to get wrong because of the event's name.

## Copilot CLI parity gaps relevant to the provider

The Agent Host Copilot provider already owns the local SDK client, models, session lifecycle, session config, worktree creation, shell tools, permissions, customization conversion, and SDK event mapping. When comparing it with the extension-host Copilot CLI implementation, the remaining relevant gaps are mostly around "make the session shippable and diagnosable" rather than core lifecycle.

The most important gap is that `_resolveSessionWorkingDirectory` creates an isolated git worktree and branch, but the provider layer has no equivalent of the extension-host request lifecycle that commits or checkpoints dirty worktree state after a turn. Worktree creation is necessary for selfhosting, but not sufficient for shipping: without a turn-end commit/checkpoint flow, edits can remain only as uncommitted files in the worktree and be invisible to a parent-repo merge or PR flow.

Copilot-specific SDK tool display is also much thinner in `copilotToolDisplay.ts` than in the extension-host CLI's `copilotCLITools.ts`. The Agent Host display helper handles core shell/file/search/web/user/subagent tools, but does not currently normalize or capture specialized Copilot CLI tools such as `exit_plan_mode`, `create_pull_request`, `skill`, or `update_todo`. If those SDK tools are expected in Agent Host sessions, provider-side display/result handling should preserve their structured meaning rather than rendering them as generic tools.

MCP support exists through plugin conversion (`toSdkMcpServers`), but the provider does not currently mirror the extension-host `CopilotCLIMCPHandler` behavior that proxies all VS Code-configured MCP servers through the gateway, adds the built-in GitHub MCP fallback, and remaps custom-agent tool names from friendly names to gateway names. That should be treated as a capability gap; the exact extension HTTP/lock-file transport is not necessarily the right Agent Host shape.

Provider logging is broad (`CopilotAgentSession._subscribeForLogging`), but it is not the same as the extension-host request logger and OTel bridge. For selfhosting investigations, the useful parity target is correlated turn/request/tool/hook/span diagnostics, not necessarily the same extension implementation.

## Testing Pattern

Focused tests live in `copilotAgent.test.ts`. The SDK client is injected through a narrow protected factory seam because the SDK `CopilotClient` type has private members, which prevents lightweight structural fakes from being assigned to the class type directly.

For database-sensitive behavior, prefer real in-memory `SessionDatabase(':memory:')` instances where possible. The Copilot provider tests keep a small fake `ISessionDataService` only to control which session IDs have an existing database; the database implementation itself is real. This lets tests assert both the positive path (stored metadata is read) and the negative path (`listSessions()` does not call `openDatabase()` for unowned SDK sessions).

For end-to-end flows that involve session lifecycle (create → resume → sendMessage → restore), the test file defines a `TestableCopilotAgent` subclass that overrides `_resumeSession` to splice in a fake session implementing the minimal `IFakeAgentSession` interface (`send`, `getMessages`, `dispose`). Both `_resumeSession` and `_resolveSessionWorkingDirectory` are `protected` on `CopilotAgent` for this purpose. This is what makes it possible to write tests that actually exercise the full path through `sendMessage` and `getSessionMessages` without spinning up the real SDK — preferred over tests that only verify a helper's string concatenation in isolation.

Tests under `src/vs/platform/agentHost/test/node/` have two hygiene rules that are easy to trip on:

- **Don't import from `'path'`.** Use `URI.joinPath(...)` and string-concat against `os.tmpdir()` instead. The repo lint blocks the `path` import.
- **No `as unknown as T` style assertions.** Blocked by `local/code-no-dangerous-type-assertions`. If a generic helper signature would force one, refactor to a non-generic signature with a narrow type alias and a single safe cast inside the helper after a runtime discriminant check (`m.type === 'message' && m.role === 'assistant'`).

Run via `npm run test-node -- --grep <pattern>`. Don't use `scripts/test.sh` — it depends on Electron and crashes outside an interactive session.

## Session-State Auto-Approval

`CopilotAgentSession.handlePermissionRequest` auto-approves file reads and writes that target the session's own state directory: `~/.copilot/session-state/<sessionId>/`. This mirrors the Copilot CLI extension's behavior (see `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts`).

The trusted directory is derived by `getCopilotCLISessionStateDir()`:

1. Check `process.env.XDG_STATE_HOME` — if set, use `$XDG_STATE_HOME/.copilot/session-state`.
2. Otherwise use `INativeEnvironmentService.userHome.fsPath` + `/.copilot/session-state`.

The per-session path appends the session ID (from `_getInternalSessionResourcePath`). Both the session directory and the incoming permission path are run through `normalizePath()` before `isEqualOrParent()` comparison, to prevent `..` traversal escapes. An additional guard checks that the session directory itself remains under the session-state root after normalization.

Write permission requests from the Copilot SDK use `request.fileName` for the target path; read requests use `request.path`. These are different shapes — not interchangeable.

Reference code in the Copilot CLI extension:
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/cliHelpers.ts` — `getCopilotCLISessionStateDir()` resolves the session-state root with XDG support.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts` — auto-approves reads and writes under the session-specific directory.

## SDK Callback Error Logging

All callbacks handed to the Copilot SDK (`handlePermissionRequest`, `handleUserInputRequest`, pre/post tool use hooks, and client tool handlers) are wrapped in try/catch that logs via `logService.error()` then rethrows. This is necessary because the SDK catches unhandled callback exceptions and converts them into generic failures (e.g., "Permission denied and could not request permission from user") with no logging. Without the wrapper, bugs like missing DI services produce untraceable permission denials.

## Managed shells (`copilotShellTools.ts`)

`ShellManager` provides per-session persistent bash/PowerShell shells backed by `IAgentHostTerminalManager` PTYs. The shells override the SDK's built-in shell tools (`overridesBuiltInTool: true`) so commands run inside our terminal infrastructure (with shell integration and the AHP terminal subscription) rather than spawning detached child processes.

**Shell history suppression** — managed shells are always created with `preventShellHistory: true`, which sets `VSCODE_PREVENT_SHELL_HISTORY=1` on the PTY env. The existing shell integration scripts in `src/vs/workbench/contrib/terminal/common/scripts/` interpret that to enable `HISTCONTROL=ignorespace` (bash), `HIST_IGNORE_SPACE` (zsh), or a no-op PSReadLine `AddToHistoryHandler`. For bash/zsh, command lines written via `executeCommandWithShellIntegration` and `executeCommandWithSentinel` are also prepended with a single space (see `prefixForHistorySuppression`) so they actually hit the env-var-controlled exclusion. PowerShell needs no prefix because PSReadLine drops everything. This mirrors the workbench's `chat.tools.terminal.preventShellHistory` behavior in `toolTerminalCreator.ts` + `commandLinePreventHistoryRewriter.ts`, but is unconditional on the agent host side (no setting yet).

## Tool display messages

`copilotToolDisplay.ts` produces the generic display fields (`displayName`, `invocationMessage`, `pastTenseMessage`, `confirmationTitle`) that flow through AHP as `StringOrMarkdown`. Plain strings are rendered as **literal text** by the chat UI — so any message containing markdown syntax (backticks for inline code, `[text](uri)` links, etc.) MUST be wrapped with the local `md()` helper so it ships as `{ markdown: ... }`. A bare string with backticks renders the backticks as visible characters.

Two rules when interpolating a runtime value into an inline-code span:

1. **Keep markdown punctuation out of the localized string.** Put the backticks (or other markdown formatting) around the `{0}` placeholder *outside* the `localize(...)` call — translators can accidentally drop or transform punctuation, which silently breaks the markdown.
2. **Use `appendEscapedMarkdownInlineCode()` from `vs/base/common/htmlContent`** to wrap user-controlled values. Backticks inside an inline code span can't be backslash-escaped per CommonMark; the helper picks a fence of backticks longer than any run in the content (and pads with spaces when needed).

So the canonical pattern is:

```ts
md(localize('key', "Searching for {0}", appendEscapedMarkdownInlineCode(truncate(args.pattern, 80))))
```

For markdown file links, `formatPathAsMarkdownLink()` already produces the `[name](uri)` form — those still go through `md(...)`.

## Shell command display rewriting (`commandLineHelpers.ts`)

Shell commands the model emits often start with a redundant `cd <workingDirectory> && …` prefix even though the SDK already runs the tool in that directory. The agent host strips that prefix at the AHP boundary so every client sees the simplified command (the SDK / PTY still runs the original verbatim — only display is rewritten).

`src/vs/platform/agentHost/common/commandLineHelpers.ts` exports two helpers:

- **`extractCdPrefix(commandLine, isPowerShell)`** — regex-based parse of `cd <dir> && …`, plus the PowerShell variants `cd /d <dir>; …`, `Set-Location <dir>; …`, `Set-Location -Path <dir> && …`. Returns `{ directory, command }` or `undefined`. Surrounding double-quotes around `<dir>` are stripped.
- **`stripRedundantCdPrefix(toolName, parameters, workingDirectory)`** — the policy wrapper. Returns `boolean` and **mutates** `parameters.command` in place when (a) `toolName` is `'bash'` or `'powershell'`, (b) the prefix matches, and (c) the extracted directory equals `workingDirectory`.

**Three independent display paths** all call `stripRedundantCdPrefix`. Adding a new place that surfaces shell command text to AHP clients should call it too:

1. **History replay** — `mapSessionEvents.ts`'s `tool.execution_start` branch. Mutates `parameters.command`, then re-stringifies into `toolArgs` and `toolInput` so both raw and display forms stay in sync.
2. **Live tool start** — `copilotAgentSession.ts` `wrapper.onToolStart` handler. Mutates the parsed `parameters` object stored in `_activeToolCalls`, then re-stringifies `toolArgs` if the rewrite happened. Because `getPastTenseMessage` in `onToolComplete` looks up `_activeToolCalls.get(callId)?.parameters`, the past-tense message automatically reflects the rewritten command — keep that aliasing intact.
3. **Permission requests** — `copilotToolDisplay.ts` `getPermissionDisplay`. Both the `'shell'` kind (synthesizes a `{ command: fullCommandText }` parameters object, then re-extracts `cleanedCommand`) and the `'custom-tool'` kind (mutates `request.args` directly when the SDK tool is a shell tool).

Path comparison normalizes separators by routing both sides through `URI.file()` (after trimming trailing separators) and comparing via `extUriBiasedIgnorePathCase.isEqual`. Don't fall back to raw `fsPath` string comparison: on Windows `URI.file('/repo/project').fsPath` is `\repo\project` while the model often emits `cd /repo/project && …`, which silently slips past a string compare.

The `pwsh &&`→`;` rewriting and the sandbox/background-detach behavior the workbench has are out of scope here. This helper only handles the redundant `cd` prefix.

## Debt & gotchas

- **debt** (2026-04-21, copilotAgent.ts:_resolveSessionWorkingDirectory) — worktree isolation creates the branch/worktree but does not provide the extension-host CLI's turn-end auto-commit/checkpoint lifecycle. Add provider/protocol-side checkpoint or commit metadata before relying on Agent Host worktree sessions as shippable branches.
- **debt** (2026-04-21, copilotToolDisplay.ts) — specialized Copilot CLI tools such as `exit_plan_mode`, `create_pull_request`, `skill`, and `update_todo` are not normalized in Agent Host display/result handling. Preserve structured semantics if these SDK tools are expected in Agent Host sessions.
- **debt** (2026-04-21, copilotPluginConverters.ts:toSdkMcpServers) — plugin MCP conversion exists, but the Agent Host path does not yet mirror extension-host MCP gateway forwarding, built-in GitHub MCP fallback, or custom-agent tool-name remapping. Add an AHP-native bridge rather than copying extension HTTP/lock-file transport directly.
- **debt** (2026-04-21, copilotAgentSession.ts:_subscribeForLogging) — provider logging is broad but lacks the extension-host request/conversation logger and SDK OTel span bridge. Selfhosting needs correlated turn, tool, hook, and span diagnostics.
- **debt** (2026-04-22, commandLineHelpers.ts:extractCdPrefix) — the `cd`-prefix extraction regex now exists in **three** copies: agent host (`commandLineHelpers.ts`), workbench (`runInTerminalHelpers.ts`), and the extension (`copilotCLITools.ts`). The agent-host version is the most complete (it includes the quoted-directory variant and PowerShell `Set-Location` / `cd /d` forms); the workbench one is missing the quoted variant. Worth a future consolidation pass into a shared `vs/base/common/` (or `vs/platform/`) helper that all three import.

- **gotcha** (2026-04-18, copilotToolDisplay.ts:getInvocationMessage/getPastTenseMessage) — display messages with markdown formatting must (a) be wrapped with `md(...)` so they ship as `{ markdown: ... }`, (b) keep the markdown punctuation (backticks, brackets) *outside* the `localize(...)` call so translators can't break it, and (c) wrap interpolated user-controlled strings with `appendEscapedMarkdownInlineCode` for inline-code spans (backslash-escaping backticks does NOT work in CommonMark inline code). A plain `string` return from a `StringOrMarkdown`-typed function renders as literal text.
- **gotcha** (2026-04-19, copilotAgentSession.ts:handlePermissionRequest) — Copilot SDK write permission requests identify the target via `request.fileName`, NOT `request.path`. Read requests use `request.path`. Mixing them up silently causes auto-approval to miss the target path and fall through to the user-confirmation codepath.
- **gotcha** (2026-04-19, copilotAgentSession.ts) — ALL callbacks handed to the Copilot SDK must wrap in try/catch + `logService.error()` + rethrow. The SDK silently swallows unhandled callback exceptions and converts them to generic error responses ("Permission denied", "Could not request input") with no logging. Without the wrapper, DI failures and other bugs in callbacks are untraceable.
- **gotcha** (2026-04-19, copilotAgentSession.ts:getCopilotCLISessionStateDir) — prefer `INativeEnvironmentService.userHome.fsPath` over `import { homedir } from 'os'` for the home directory. The service is available in the agent-host process (registered in both startup paths) and makes testing easier.

- **gotcha** (2026-04-19, copilotShellTools.ts:executeCommandWithShellIntegration/executeCommandWithSentinel) — for bash/zsh managed shells, commands are prepended with a leading space to keep them out of shell history. This relies on `VSCODE_PREVENT_SHELL_HISTORY=1` being set on the PTY env (which the shell integration scripts translate to `HISTCONTROL=ignorespace`/`HIST_IGNORE_SPACE`). If you change either side independently, history suppression silently breaks. PowerShell intentionally has no prefix — PSReadLine handles it server-side.
- **gotcha** (2026-04-19, copilotAgent.ts:prependAnnouncementToFirstAssistantMessage) — the restore path for session announcements skips messages with `parentToolCallId` so the prepend lands on the **first top-level** assistant message. If you change this to "first assistant message", the announcement gets buried inside a subagent's history and disappears from the parent turn. Keep the `!m.parentToolCallId` filter.
- **gotcha** (2026-04-19, copilotAgent.ts:sendMessage worktree announcement) — the live-path "first turn" announcement is intentionally in-process only (`_pendingFirstTurnAnnouncements` Map). It's lost if the agent process restarts between worktree creation and the first user prompt — that window is acceptable to lose, because the restore path covers every reopen once any reply exists. Don't add a DB-backed "emitted" flag to "fix" this; we tried and reverted (see `changes/2026-04-19-worktree-progress-message/`).
- **gotcha** (2026-04-19, agentService.ts:IAgentDeltaEvent) — the field is `content`, not `delta`. The event's name makes `delta` a tempting typo; producers and consumers (and the Copilot reviewer's auto-suggestions) both get this wrong.
- **gotcha** (2026-04-19, copilotAgent.test.ts) — tests under `src/vs/platform/agentHost/test/node/` cannot `import 'path'` (lint blocks it) and cannot use `as unknown as T` (blocked by `local/code-no-dangerous-type-assertions`). Use `URI.joinPath` + `os.tmpdir()`, and refactor generic helpers to a non-generic signature with a single discriminant-checked cast inside.
- **gotcha** (2026-04-19, copilotToolDisplay.ts:getSubagentMetadata) — SDK-specific argument parsing (e.g. extracting `agent_type` from the `task` tool's args) lives here, NOT in the generic `agentEventMapper.ts`. The mapper only forwards already-normalized `subagentAgentName` / `subagentDescription` event fields. The SDK's `task` tool destructures `agent_type` (snake_case) — there is no `agentName` field; don't add a fallback for one.
- **gotcha** (2026-04-20, copilotAgent.ts:listSessions / _listModels) — both methods MUST throw `AHP_AUTH_REQUIRED` (via `_ensureClient()`) when `_githubToken` is unset. Do NOT short-circuit with `return []` — that's a silent lie that violates the AHP `required: true` contract and breaks consumers that cache the first response (the Agents-app sidebar's `BaseAgentHostSessionsProvider._ensureSessionCache` is one-shot; an empty cached list never recovers until `notify/sessionAdded` fires). The renderer-side `authenticationPending` autorun is the natural retry trigger after auth settles. The historical `returns empty models and sessions before authentication` test pinned the wrong behavior as if it were a feature; updated to expect the throw.
- **gotcha** (2026-04-20, copilotAgent.ts:id + getDescriptor) — the agent's id and descriptor `provider` are `'copilotcli'`, NOT `'copilot'`. They were renamed so the agent advertises the same name the UI uses. There is no longer any alias map / "well-known agent type" indirection — what the agent advertises in `rootState.agents[].provider` is the literal string the Sessions-app provider exposes as `ISession.sessionType.id`. Don't reintroduce a `'copilot' → 'copilotcli'` mapping anywhere.
- **gotcha** (2026-04-20, copilotAgent.test.ts) — when renaming `CopilotAgent.id`, audit hardcoded literals in tests under `src/vs/platform/agentHost/test/node/` **including the real-SDK file `protocol/toolApprovalRealSdk.integrationTest.ts`**. `AgentSession.uri('copilot', ...)` constructions in tests are NOT type-checked (the parameter is `string`) so the rename slips past TypeScript and only fails in CI. Worse, the real-SDK file is gated on `AGENT_HOST_REAL_SDK=1` and is not run by CI at all, so stale provider ids there sit broken indefinitely until someone runs the suite manually. The 2026-04-20 rename caught the 7 occurrences in `copilotAgent.test.ts`; the 2026-04-21 SDK bump session caught a further 6 occurrences in `toolApprovalRealSdk.integrationTest.ts` that had been failing silently with `No agent provider registered for: copilot` ever since.
- **gotcha** (2026-04-21, updated 2026-04-22, package.json:@github/copilot) — the root `package.json` and `remote/package.json` versions of `@github/copilot` should track `extensions/copilot/package.json`. The copilot extension ships with VS Code and is exercised by Copilot's own validation, so its pinned version is the known-good baseline. Bump in lockstep with it. Note that `@github/copilot-sdk`'s `.d.ts` types and the bundled CLI server's runtime JSON schema (`@github/copilot/schemas/api.schema.json`) drift independently across releases — adapter code in `copilotAgent.ts` should not trust SDK types as gospel for runtime shapes (see the `ICopilotModelInfo` wrapper gotcha below).
- **gotcha** (2026-04-22, copilotAgent.ts:ICopilotModelInfo + IAgentModelInfo.maxContextWindow) — at `@github/copilot@1.0.34` the synthetic `auto` router model is returned by `listModels()` with `capabilities: {}` — no `limits`, no `supports`. The SDK's `ModelInfo` declares `capabilities.limits.max_context_window_tokens` as required, so a naive dereference throws `TypeError: Cannot read properties of undefined (reading 'max_context_window_tokens')` and `_refreshModels`'s catch swallows it (empty model list, see next gotcha). Two-part fix kept locally rather than reported upstream: (1) `ICopilotModelInfo` in `copilotAgent.ts` is a hand-typed wrapper that re-declares the same fields with `capabilities`, `limits`, `supports`, and `max_context_window_tokens` all optional — `ICopilotClient.listModels` is typed against the wrapper, not the raw SDK type, so direct dereferences are properly nullable-checked at compile time; (2) `IAgentModelInfo.maxContextWindow` in `agentService.ts` is `number | undefined` so `_listModels` can `.map` (not `.flatMap`) and pass `auto`'s undefined through — the consumer in `agentHostLanguageModelProvider.ts` already coalesces with `?? 0`. The `auto` model MUST surface — dropping it (the first instinct) breaks the router-mode picker. When upstream typing/runtime drift bites again, prefer extending `ICopilotModelInfo` over adding `?.` chains scattered through the consumer code.
- **gotcha** (2026-04-21, copilotAgent.ts:_refreshModels) — the `try { await _listModels() } catch { _models = [] }` block silently swallows **every** error, not just the `AHP_AUTH_REQUIRED` it was designed for. SDK schema mismatches, network errors, anything throwing inside `_listModels` produce the same symptom: empty model list in the UI with no surfaced error and no log. The only safety net is the real-SDK `listModels returns well-shaped model entries after authenticate` integration test in `protocol/toolApprovalRealSdk.integrationTest.ts`, which asserts the full model shape. If you change `_listModels`, run that test (`AGENT_HOST_REAL_SDK=1 ./scripts/test-integration.sh --runGlob "**/agentHost/**/toolApprovalRealSdk.integrationTest.js" --grep listModels`).
- **gotcha** (2026-04-22, copilotAgentSession.ts) — the Agent Host imports the **public** SDK `@github/copilot-sdk`. The Copilot CLI extension (`extensions/copilot/src/extension/chatSessions/copilotcli/`) imports the **private** SDK `@github/copilot/sdk` (a sibling export from the same `@github/copilot` package). They expose substantially different surfaces — do not assume parity. Concrete differences observed at `@github/copilot@1.0.34` / `@github/copilot-sdk@0.2.2`:
	- **Plan-mode entry**: private SDK accepts `agentMode: 'interactive' | 'plan' | 'autopilot' | 'shell'` on `SendOptions` and exposes a mutable `session.currentMode`. Public SDK's `MessageOptions` has no `agentMode` field at all — there is no way to put a session into plan mode through the public surface.
	- **Plan-mode response**: private SDK exposes `Session.respondToExitPlanMode(requestId, response)`. Public SDK's `Session` does not — the `exit_plan_mode.requested` event type IS in the public `SessionEvent` union and you can `session.on(...)` it, but there is no responder API to close the loop.
	- **`SessionOptions.onExitPlanMode`** exists on both, but in the public SDK it's `protected` and not exposed via `ResumeSessionConfig` — wiring it from `CopilotAgent.createSessionConfig()` is not possible through the public surface.

	The next time someone reads the extension's plan-mode code (`copilotcliSession.ts` + `exitPlanModeHandler.ts`) and tries to port it to `copilotAgentSession.ts`, they will hit this wall — the missing surface area is the reason `planning-mode session-state writes are auto-approved in default mode` in `protocol/toolApprovalRealSdk.integrationTest.ts` is currently `test.skip`'d. Update this entry (and unskip the test) when the public SDK adds these surfaces.

- **gotcha** (2026-04-22, commandLineHelpers.ts:stripRedundantCdPrefix) — shell command text reaches AHP clients through **three independent paths**: history replay (`mapSessionEvents.ts` `tool.execution_start`), live tool start (`copilotAgentSession.ts` `wrapper.onToolStart`), and permission requests (`copilotToolDisplay.ts` `getPermissionDisplay` for both `'shell'` and `'custom-tool'`). When adding a new shell-command rewrite (or any other "make this command look nicer to clients" transform), call the shared helper from all three paths or the rewrite will look correct on session reload but be missing during live execution / permission prompts. The first version of the cd-prefix strip only patched history replay; the live paths surfaced as a "works after reopen, broken in the moment" bug.
- **gotcha** (2026-04-22, commandLineHelpers.ts:stripRedundantCdPrefix) — comparing a path extracted from a model-emitted command line (e.g. the `<dir>` from `cd <dir> && …`) against the session `workingDirectory: URI` MUST go through `URI.file(...)` + `extUriBiasedIgnorePathCase.isEqual` (with trailing separators trimmed off both sides), not raw `fsPath` string comparison. On Windows `URI.file('/repo/project').fsPath` is `\repo\project`, but the model commonly emits forward-slash paths (`cd /repo/project && …`); a string compare silently misses every match and the regression only surfaces on Windows CI. The same applies to any other place that extracts a path from free-form command-line text.

## Related

- [agent-host-topology](./agent-host-topology.md) — where provider-level listing work fits in the Agent Host architecture.
- [agent-host-protocol](./agent-host-protocol.md) — why this behavior is provider persistence, not a protocol change.
- [agent-host-session-handler](./agent-host-session-handler.md) — downstream turn and chat integration after a session is selected.

## Changelog

- **2026-04-22** — `357bfe70c9` — added `commandLineHelpers.ts` + `mapSessionEvents.ts` to Covers; documented the new `extractCdPrefix` / `stripRedundantCdPrefix` helpers and the **three independent shell-command display paths** (history replay, live `tool_start`, permission requests) that all rewrite the redundant `cd <workingDirectory>` prefix at the AHP boundary; added two gotchas (three-path coverage, `URI.file` + `extUriBiasedIgnorePathCase.isEqual` for cross-platform path comparison) and one debt entry (three copies of the `extractCdPrefix` regex now live in workbench / extension / agent host). See [changes/2026-04-22-agent-host-cd-cleanup](../changes/2026-04-22-agent-host-cd-cleanup/summary.md).
- **2026-04-22** — `a92cbe70e9` — added gotcha documenting the public vs private SDK split (`@github/copilot-sdk` vs `@github/copilot/sdk`). The Agent Host uses the public SDK; the Copilot CLI extension uses the private one. Concrete differences observed: plan-mode entry (`agentMode` on `SendOptions`), plan-mode response (`Session.respondToExitPlanMode`), and the `onExitPlanMode` callback wiring. This is the load-bearing reason `planning-mode session-state writes are auto-approved in default mode` is currently `test.skip`'d in `toolApprovalRealSdk.integrationTest.ts`. Cross-referenced from the testing doc.
- **2026-04-22** — `d6e5c5227d` — bumped `@github/copilot` from `^1.0.28` to `^1.0.34` (matches `extensions/copilot`); added `ICopilotModelInfo` wrapper interface with optional `capabilities`/`limits`/`supports`/`max_context_window_tokens`, made `IAgentModelInfo.maxContextWindow` optional, and switched `_listModels` to `.map` so the synthetic `auto` model (which ships with `capabilities: {}`) surfaces with `maxContextWindow: undefined` instead of throwing or being dropped. Updated the related gotcha and added a new one for the wrapper-interface pattern; updated `testing.md` § 3 example accordingly.
- **2026-04-21** — `ad531180d0` — added Copilot CLI parity-gap section and debt entries for worktree commit/checkpoint lifecycle, specialized Copilot CLI tool display, MCP gateway parity, and request/OTel logging.
- **2026-04-21** — `4da62d3b09` — added gotchas for: (1) `package.json` / `remote/package.json` `@github/copilot` version should track `extensions/copilot/package.json`'s pin; (2) `_refreshModels` swallows ALL throws (not just auth), so the only safety net for SDK schema drift is the new real-SDK `listModels` integration test; (3) extended the rename-audit gotcha to call out `protocol/toolApprovalRealSdk.integrationTest.ts` — env-gated so stale provider ids sit broken indefinitely.
- **2026-04-21** — `7bc767483b` — added coexistence paragraph to Session Ownership section explaining how the database-existence gate pairs with the extension provider's `getSessionOrigin()` filter. Cross-links to new [agent-host-sessions-providers § Coexistence](./agent-host-sessions-providers.md#coexistence-with-the-extension-host-provider).
- **2026-04-20** — `d05eca7455` — added "Authentication contract" section documenting that `listSessions` and `_listModels` throw `AHP_AUTH_REQUIRED` via `_ensureClient()` when no token (per AHP `required: true` spec); added gotcha against silently returning `[]` and noted the prior test that pinned the wrong behavior.

- **2026-04-17** — `9364e338cc` — initial entry documenting CopilotAgent SDK session filtering, database-backed ownership, metadata keys, and focused test seams.
- **2026-04-18** — `ef2cdf49e1` — added `copilotToolDisplay.ts` to Covers; documented the `md()` wrapping requirement, the keep-markdown-out-of-localize rule, and the `appendEscapedMarkdownInlineCode` helper for `StringOrMarkdown` display fields, with a gotcha entry covering all three.
- **2026-04-19** — `e625d61aa4` — added `copilotShellTools.ts` to Covers; documented `ShellManager` managed shells and the always-on shell-history suppression (env var + leading-space prefix) that mirrors the workbench `commandLinePreventHistoryRewriter`.
- **2026-04-19** — `bea3e7e018` — added `copilotAgentSession.ts` and `copilotAgentSession.test.ts` to Covers; documented session-state auto-approval in `handlePermissionRequest`, SDK callback error logging, and four gotchas (write `fileName` vs `path`, SDK swallows exceptions, prefer env service, traversal normalization).
- **2026-04-19** — `adc4f6e17e` — documented the worktree-creation session announcement (live delta + restore-path prepend, dual paths against the same markdown via `_pendingFirstTurnAnnouncements` and `copilot.worktree.branchName` metadata); added the `copilot.worktree.branchName` metadata key; expanded the testing pattern with `TestableCopilotAgent` / `IFakeAgentSession` and the `test/node/` hygiene rules (no `'path'` import, no `as unknown as T`); added gotchas for the subagent-skip in the restore prepend, the deliberately-non-persistent live path, the `IAgentDeltaEvent.content` field name, and the test-file lint rules.
- **2026-04-19** — `2935e7d695` — added gotcha: SDK-specific arg parsing for the `task` tool (`agent_type`) lives in `getSubagentMetadata`, not the generic `agentEventMapper`. Removed dead `agentName` fallback (the SDK never emits that field).
- **2026-04-20** — `00f882a16c` — renamed `CopilotAgent.id` and the descriptor `provider` from `'copilot'` to `'copilotcli'`. Updated `AgentSession.uri('copilot', ...)` reference. Added gotchas: don't reintroduce alias maps for the rename; on-disk DB key derives from raw session id (not URI scheme) so the rename does not migrate old data; audit hardcoded id literals in test files (the `string` parameter slips past TypeScript). Cross-linked the new [2026-04-20 routing-fix change summary](../changes/2026-04-20-remote-agent-session-routing-fix/summary.md).
- **2026-04-21** — `ad531180d0` — reconciliation: repaired a malformed changelog entry from the prior rename update; no covered Copilot-provider commits since `4da62d3b09` required body changes.
