# Copilot SDK Permissions

_Covers: src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts, src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts, src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts_

`CopilotAgentSession` handles Copilot SDK permission and user-input callbacks for the Agent Host provider. It is a parallel implementation of the extension-host CLI permission path in `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts`, but it should expose behavior through Agent Host/AHP concepts rather than sharing extension-host code directly.

## Session-state auto-approval

`CopilotAgentSession.handlePermissionRequest` auto-approves file reads and writes that target the session's own state directory: `~/.copilot/session-state/<sessionId>/`. This mirrors the Copilot CLI extension's behavior.

The trusted directory is derived by `getCopilotCLISessionStateDir()`:

1. Check `process.env.XDG_STATE_HOME` — if set, use `$XDG_STATE_HOME/.copilot/session-state`.
2. Otherwise use `INativeEnvironmentService.userHome.fsPath` + `/.copilot/session-state`.

The per-session path appends the session ID from `_getInternalSessionResourcePath`. Both the session directory and the incoming permission path are run through `normalizePath()` before `isEqualOrParent()` comparison, to prevent `..` traversal escapes. An additional guard checks that the session directory itself remains under the session-state root after normalization.

Write permission requests from the Copilot SDK use `request.fileName` for the target path; read requests use `request.path`. These are different shapes — not interchangeable.

Reference code in the Copilot CLI extension:

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/cliHelpers.ts` — `getCopilotCLISessionStateDir()` resolves the session-state root with XDG support.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts` — auto-approves reads and writes under the session-specific directory.

## SDK callback error logging

All callbacks handed to the Copilot SDK (`handlePermissionRequest`, `handleUserInputRequest`, pre/post tool use hooks, and client tool handlers) are wrapped in try/catch that logs via `logService.error()` then rethrows. This is necessary because the SDK catches unhandled callback exceptions and converts them into generic failures (for example, "Permission denied and could not request permission from user") with no logging. Without the wrapper, bugs like missing DI services produce untraceable permission denials.

## Attachments to SDK payload

`_toSdkAttachment(attachment: MessageAttachment)` translates a protocol `MessageAttachment` into the Copilot SDK's `attachments` payload shape. Resource attachments map to the SDK's reference-style `file`/`directory`/`selection` variants (the `displayKind` advisory hint controls which one, but a `TextSelection`-carrying attachment always maps to `selection` regardless of `displayKind` — keying off the `selection` field rather than `displayKind` alone avoids symbol attachments degrading to a plain file reference, [#315193](https://github.com/microsoft/vscode/issues/315193)). Embedded resources map to the SDK's `blob` variant — this now covers both inline image bytes and **unsaved editor content** (PR [#321591](https://github.com/microsoft/vscode/pull/321591)): a textual embedded resource already carries the exact inline text to send (the whole live buffer for a document, or just the selected text for a selection), so it's forwarded as-is without re-slicing. Selections without inline text (a `Resource` attachment carrying only a range) still read the file from disk and slice by the carried range, downgrading to a plain file reference on read failure. Simple attachments with a model representation map to `text/plain` blob attachments.

## Subagent event routing

`CopilotAgentSession` must route SDK events to the correct AHP session scope — parent or one of its subagents. The key routing state:

- **`_parentToolCallIdsByAgentId: Map<string, string>`** — populated by `onSubagentStarted`. When the SDK fires `subagent.started`, the event carries both the SDK-level `agentId` (event-scoped identifier for the subagent process) and the `toolCallId` that spawned it. This map records `agentId → toolCallId`.
- **`_parentToolCallIdForSubagentEvent(e)`** — looks up `e.agentId` in the map; returns `undefined` if the agent is unmapped (e.g. if the event arrives out of order before `subagent.started`).
- **`_shouldDropUnmappedSubagentEvent(e, eventName)`** — if `agentId` has no mapping, logs a warning and returns `true`. Events with unmapped `agentId` are **dropped**, not buffered. The SDK guarantees `subagent.started` fires before any child `agentId`-tagged events; out-of-order events indicate an SDK contract violation.

**Why `agentId`, not `data.parentToolCallId`:** The Copilot SDK deprecated `data.parentToolCallId` in favor of event-level `agentId` fields. Do not use `data.parentToolCallId` for routing; it is not reliably populated and may be absent in new SDK versions.

**Per-subagent response part IDs:** `_currentMarkdownPartIds` and `_currentReasoningPartIds` are `Map<string, string>` keyed by `parentToolCallId ?? ''` (the empty-string key covers the root/parent session). A single global for each would cause subagent text deltas to overwrite the parent session's active part tracker: after the subagent finishes and the parent resumes streaming its final reply, the parent's `onMessageDelta` would see a stale part id and fail to open/continue the correct markdown part. The result is the final parent assistant message never rendering live (it only appears after a nav away and back, which forces a restore from disk).

Note the `agentId`-keyed routing above is distinct from the `parentToolCallId` field now threaded onto the `subagent_started` **signal** dispatched to `AgentSideEffects` (PR [#323815](https://github.com/microsoft/vscode/pull/323815), added to fix nested/depth-2+ subagent client-tool stalls). That `parentToolCallId` is read from `_activeToolCalls.get(e.data.toolCallId)?.parentToolCallId` — one hop up, the tool call in whose chat the spawning tool itself lives — and is used purely for **content-block chat routing** on the renderer side, not for the `agentId`-keyed SDK event routing described above.

## Auto-reply for user input requests

`_handleUserInputRequest` auto-answers the SDK's `ask_user` tool (rather than surfacing an AHP input-request to the client) when either autopilot mode is active **or** `_isAutoReplyEnabled()` returns true. `_isAutoReplyEnabled()` reads the `chat.autoReply` setting (`AgentHostAutoReplyEnabledConfigKey`) via `_configurationService.getRootValue(platformRootSchema, ...)`. The synthesized answer text is: *"The user is not available to answer your question. Choose a pragmatic option best aligned with the context of the request."* This mirrors the existing autopilot-mode auto-answer path — `chat.autoReply` extends it to non-autopilot sessions where the user has explicitly opted into unattended responses.

## MCP authentication requests

`CopilotAgentSession.resolveMcpAuthentication(params: AuthenticateParams)` resolves a pending MCP auth request tracked in `_pendingMcpAuthRequests: Map<string, ...>`. The matching helpers are `_handleMcpAuthRequest` (registers a pending request when the SDK reports one), `_protectedResourceFromMcpAuthRequest` / `_requiredScopesFromMcpAuthRequest` (extract the resource/scopes the SDK is asking for), and `_scopesSatisfy` (checks an incoming token's scopes cover what was requested). Auth state is keyed on a stable tuple — session authority, MCP server name, and resource URL — rather than the (unstable, resync-sensitive) customization id, so a previously granted auth survives a customization re-sync. `CopilotAgent.handleAuthenticationToken(params)` is the entry point that receives the token and fans it out to `resolveMcpAuthentication` on every chat session; see [copilot-agent-provider § MCP authentication](./copilot-agent-provider.md#mcp-authentication) for the session-plugin-controller side (live `mcpServerStates` overlay onto published customizations).

## Debt & gotchas

- **gotcha** (2026-04-19, copilotAgentSession.ts:handlePermissionRequest) — Copilot SDK write permission requests identify the target via `request.fileName`, NOT `request.path`. Read requests use `request.path`. Mixing them up silently causes auto-approval to miss the target path and fall through to the user-confirmation codepath.
- **gotcha** (2026-04-19, copilotAgentSession.ts) — ALL callbacks handed to the Copilot SDK must wrap in try/catch + `logService.error()` + rethrow. The SDK silently swallows unhandled callback exceptions and converts them to generic error responses ("Permission denied", "Could not request input") with no logging. Without the wrapper, DI failures and other bugs in callbacks are untraceable.
- **gotcha** (2026-04-19, copilotAgentSession.ts:getCopilotCLISessionStateDir) — prefer `INativeEnvironmentService.userHome.fsPath` over `import { homedir } from 'os'` for the home directory. The service is available in the agent-host process (registered in both startup paths) and makes testing easier.
- **gotcha** (2026-05-04, copilotAgentSession.ts:_parentToolCallIdsByAgentId) — subagent events carry an event-level `agentId` field, NOT the deprecated `data.parentToolCallId`. The routing map (`agentId → toolCallId`) is populated by `subagent.started`. Do not read `data.parentToolCallId` for routing; it is absent in current SDK versions.
- **gotcha** (2026-05-04, copilotAgentSession.ts:_currentMarkdownPartIds / _currentReasoningPartIds) — these are `Map<string, string>` keyed by `parentToolCallId ?? ''`, NOT single globals. Using a single global causes subagent text deltas to clobber the parent session's active part id; after the subagent completes, the parent's final assistant message never appends to the right part during live streaming (the message renders only after a nav-away-and-back restore). The empty-string key represents the root/parent session scope.
- **gotcha** (2026-07-02, copilotAgentSession.ts:subagent_started.parentToolCallId vs _parentToolCallIdsByAgentId) — don't conflate the two `parentToolCallId`-shaped mechanisms. `_parentToolCallIdsByAgentId` (above) routes **SDK events** to the right session scope by `agentId`. The signal-level `parentToolCallId` added in PR [#323815](https://github.com/microsoft/vscode/pull/323815) (`this._activeToolCalls.get(e.data.toolCallId)?.parentToolCallId`) routes a **discovery content block** to the immediate parent chat for nested (depth ≥ 2) subagents; it's read once at `subagent_started` dispatch time, not maintained as a lookup map.

## Related

- [copilot-agent-provider](./copilot-agent-provider.md) — provider lifecycle and session ownership.
- [copilot-extension-host-cli](./copilot-extension-host-cli.md) — extension-host permission helper reference.
- [copilot-sdk-shells](./copilot-sdk-shells.md) — shell-tool permission asymmetry.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — permission display rendering for shell/custom tools.

## Approval modes

New agent sessions start in one of three approval modes selected by the `chat.defaultConfiguration` setting (`ChatConfiguration.DefaultConfiguration`, shape `IChatDefaultConfiguration`): **Interactive** (step-by-step collaboration), **Plan** (plan first, execute when ready), and **Autopilot** (autonomously iterate from start to finish). The `approvals` sub-property selects the approval policy (Default Approvals = use the user's configured settings). Elevated-mode confirmation flows through `maybeConfirmElevatedPermissionLevel(...)` with `defaultSettingKey: ChatConfiguration.DefaultConfiguration`.

Approval mode also gates the SDK **sandbox**: `_isBypassApprovals()` (true under global auto-approve, autopilot, or a session `autoApprove` setting of `'autoApprove'`) makes `_computeSdkSandboxConfig()` skip sandboxing entirely, and `_applyEffectiveSandboxConfig()` re-pushes the effective config before every `send()` rather than once at session launch. See [copilot-sdk-shells § Sandboxed shell execution](./copilot-sdk-shells.md#sandboxed-shell-execution) for the sandbox config shape and the bypass-permission-title behavior.

## Changelog

- **2026-07-02** — f9f2fd558a — reconciliation: added **Attachments to SDK payload** (`_toSdkAttachment`, embedded resources now also cover unsaved editor content via PR [#321591](https://github.com/microsoft/vscode/pull/321591)), **Auto-reply for user input requests** (`_isAutoReplyEnabled()` / `chat.autoReply`, extends the autopilot auto-answer path), and **MCP authentication requests** (`resolveMcpAuthentication`, `_pendingMcpAuthRequests`, stable auth-state keying) sections; cross-linked the sandbox approval-mode gating into **Approval modes**; added a gotcha distinguishing the `agentId`-keyed subagent event routing from the new signal-level `subagent_started.parentToolCallId` (PR [#323815](https://github.com/microsoft/vscode/pull/323815)) used for content-block chat routing. Commits: `ed577eeefb6`, `17c6cd4836d`, `afc6859cd3e`, `50055f97fc5`, `c0cc253a971`, `a91385696d0`.

- **2026-06-25** — 09c18fe5c5 — reconciliation: added an **Approval modes** section (Interactive / Plan / Autopilot via `chat.defaultConfiguration` / `ChatConfiguration.DefaultConfiguration` / `IChatDefaultConfiguration`, `approvals` sub-property, `maybeConfirmElevatedPermissionLevel`). The auto-approval, callback-error-logging, and subagent-routing contract is otherwise unchanged.

- **2026-05-15** — 12443ea83d — reconciliation: no permission-contract prose changes. Elicitation, replay, and tool-display commits touched nearby Copilot session files, but the existing auto-approval, callback error logging, and subagent routing guidance remains current.

- **2026-05-04** — 81095cbaba — added "Subagent event routing" section documenting `_parentToolCallIdsByAgentId`, event-level `agentId` routing, `_shouldDropUnmappedSubagentEvent`, and per-subagent `_currentMarkdownPartIds`/`_currentReasoningPartIds` Maps. Added two gotchas: `data.parentToolCallId` is deprecated (use event-level `agentId`); the part-id Maps must be per-subagent or the parent's final live message is clobbered.
- **2026-05-01** — b2e6267136 — reconciliation: no body changes. The auto-approve / plan-mode / activity-event commits in this range preserve the existing permission-callback architecture; the dedicated picker changes are documented in `agent-host-auto-approve-picker.md`.
- **2026-04-24** — 4b6403a3ab — split permission handling and SDK callback safety out of the Copilot provider overview
