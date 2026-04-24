# Copilot Agent Provider

_Covers: src/vs/platform/agentHost/node/copilot/copilotAgent.ts, src/vs/platform/agentHost/test/node/copilotAgent.test.ts_

`CopilotAgent` is the local Agent Host provider backed by the Copilot SDK. It is provider-specific code under `src/vs/platform/agentHost/node/copilot/`, below the generic AHP server layer and above the SDK runtime. Generic aggregation (`AgentService`) and UI consumers should receive already-filtered Copilot session metadata from this provider.

This doc covers provider lifecycle, metadata, ownership, authentication, session announcements, and provider-level tests. Provider-adjacent SDK details are split by concern:

- [copilot-extension-host-cli](./copilot-extension-host-cli.md) - extension-host Copilot CLI reference points and parity gaps for selfhosting.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) - permission callbacks, session-state auto-approval, and SDK callback error logging.
- [copilot-sdk-shells](./copilot-sdk-shells.md) - managed shell tools, shell-tool permission asymmetry, and shell-history suppression.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) - SDK tool display messages, command display rewriting, and history/live/permission display paths.

## Responsibilities

`CopilotAgent` owns:

- Starting and stopping the SDK `CopilotClient`, including the clean subprocess environment used for the CLI server.
- Advertising Copilot models and protected resources.
- Creating, forking, resuming, listing, disposing, aborting, truncating, and changing model selection for Copilot sessions.
- Building SDK session config from active client tools, customizations, hooks, MCP servers, custom agents, skills, and shell tools.
- Persisting provider-local metadata in the per-session Agent Host database.

It does not own AHP state shape or workbench rendering. Contract changes belong in [agent-host-protocol](./agent-host-protocol.md); turn execution and rendering belong in [agent-host-session-handler](./agent-host-session-handler.md).

## Authentication contract

`listSessions()` and `_listModels()` both go through `_ensureClient()`, which throws `ProtocolError(AHP_AUTH_REQUIRED, ...)` when `_githubToken` is unset. This is required by the AHP spec: Copilot's `protectedResources` declares `required: true`, which the [authentication spec](https://github.com/microsoft/agent-host-protocol/blob/main/docs/specification/authentication.md) mandates the server return `AuthRequired` (-32007) for, not silently respond with empty data.

`_refreshModels()` is the only caller that swallows the throw. It guards on `!_githubToken` first and catches errors because the models observable has no other natural retry path. Everything else relies on the renderer-side `authenticationPending` autorun in [`LocalAgentHostSessionsProvider`](./agent-host-sessions-providers.md#one-shot-_ensuresessioncache--auth-aware-eager-load) to drive the retry.

Returning `[]` instead of throwing was a real bug: it caused the Agents-app sidebar to never display sessions on a fresh launch because the renderer's one-shot cache held the empty response forever. Only `notify/sessionAdded` from the user's first message broke the deadlock. See [changes/2026-04-20-fix-initial-session-list-display](../changes/2026-04-20-fix-initial-session-list-display/summary.md).

## Session ownership

The Copilot SDK can list sessions that were created outside VS Code's Agent Host, such as sessions from other Copilot CLI agents. `CopilotAgent.listSessions()` is responsible for filtering SDK results down to sessions that VS Code Agent Host owns or has already adopted.

The ownership signal is the existence of a per-session Agent Host database. `listSessions()` constructs the canonical `AgentSession.uri('copilotcli', sessionId)` for each SDK result and calls `ISessionDataService.tryOpenDatabase()`. If no database exists, the SDK session is skipped. This check must happen before project resolution or any metadata write so listing does not create databases for unrelated SDK sessions.

> **`CopilotAgent.id` is `'copilotcli'`.** It used to be `'copilot'`; renamed in the [2026-04-20 session-routing change](../changes/2026-04-20-remote-agent-session-routing-fix/summary.md) to align the agent's advertised provider name with the UI session-type id. The on-disk per-session DB key derives from the raw session id (`AgentSession.id(uri) = uri.path.substring(1)`), not the URI scheme, so the rename does not invalidate stored databases. Old `copilot:///<sid>` URIs and new `copilotcli:///<sid>` URIs hit the same DB row.

Any existing per-session database qualifies as owned. This intentionally keeps the rule simple: sessions created by Agent Host already create a database when metadata is stored, and older sessions with database metadata continue to appear. The implementation does not persist a separate Copilot ownership marker.

After a session passes the database gate, `listSessions()` may resolve project metadata and store the resolution to avoid rediscovering git context on later lists. That write is safe because the database already existed before the list operation considered the session owned.

This database-existence gate is the local-agent-host half of the coexistence contract with the extension-host `CopilotChatSessionsProvider`. The extension provider has its own symmetric filter via `IChatSessionMetadataStore.getSessionOrigin()`: sessions without the extension's per-session JSON metadata return `'other'` and are excluded. Together these two filters ensure each provider shows only its own sessions with no overlap. See [agent-host-sessions-providers § Coexistence](./agent-host-sessions-providers.md#coexistence-with-the-extension-host-provider).

## Metadata

Copilot provider metadata is stored in the session database's `session_metadata` table. Current keys include:

- `copilot.model` - serialized `IModelSelection`, including model config such as reasoning effort.
- `copilot.workingDirectory` - URI string for the session working directory.
- `copilot.project.resolved` - marker that project resolution was attempted.
- `copilot.project.uri` and `copilot.project.displayName` - cached project identity for list metadata.
- `copilot.worktree.branchName` - set when isolation is `worktree`. Used by the restore path of the [session announcements](#session-announcements-worktree-creation) feature to reconstruct the "Created isolated worktree for branch X" message when a session is reopened.

Use `tryOpenDatabase()` for read-only checks that must not create session data. Use `openDatabase()` only on paths that intentionally create or update Agent Host-owned session data.

## Session announcements (worktree creation)

When `_resolveSessionWorkingDirectory` creates an isolated worktree, the user should see a "Created isolated worktree for branch `X`" message at the top of the very first response, both live as the model is replying and on every subsequent reopen of the session.

The message is plain markdown, so it is surfaced through the existing AHP delta channel rather than a dedicated event type. There are two paths and they are independent:

1. **Live path (first turn only).** `_resolveSessionWorkingDirectory` populates `_pendingFirstTurnAnnouncements: Map<sessionId, string>` with the rendered markdown. The first call to `sendMessage` for that session drains the entry (one-shot `get` + `delete`) and fires a synthetic `IAgentDeltaEvent` whose `messageId` is `copilot-announcement-<uuid>` before delegating to the SDK. The session-handler mapper appends the SDK's subsequent deltas to the same markdown part, so the announcement and the model's reply render as one continuous markdown block.
2. **Restore path (every reopen, including across process restarts).** `getSessionMessages` reads `copilot.worktree.branchName` via `tryOpenDatabase()` and calls the local `prependAnnouncementToFirstAssistantMessage(messages, text)` helper. It walks the message list and prepends the announcement to the first top-level assistant message: `m.type === 'message' && m.role === 'assistant' && !m.parentToolCallId`. Subagent inner messages are skipped on purpose so the announcement lands on the parent turn, not buried inside a subagent's history. If no top-level assistant message exists yet, the messages are returned unchanged. The live path is the only thing that fires before any reply has been recorded, and the announcement is acceptable to lose if the agent process restarts in that narrow window.

The announcement text is built by the local `buildWorktreeAnnouncementText(branchName)`: a `localize(...)` call that wraps `branchName` with `appendEscapedMarkdownInlineCode(...)` (see [tool display messages](./copilot-sdk-tool-display.md#tool-display-messages) for the same rule applied to tool messages) and ends with `\n\n` so it visually separates from whatever follows when concatenated.

The `IAgentDeltaEvent` field is `content`, not `delta`. This typo is easy because of the event's name.

## Testing pattern

Focused tests live in `copilotAgent.test.ts`. The SDK client is injected through a narrow protected factory seam because the SDK `CopilotClient` type has private members, which prevents lightweight structural fakes from being assigned to the class type directly.

For database-sensitive behavior, prefer real in-memory `SessionDatabase(':memory:')` instances where possible. The Copilot provider tests keep a small fake `ISessionDataService` only to control which session IDs have an existing database; the database implementation itself is real. This lets tests assert both the positive path (stored metadata is read) and the negative path (`listSessions()` does not call `openDatabase()` for unowned SDK sessions).

For end-to-end flows that involve session lifecycle (create -> resume -> sendMessage -> restore), the test file defines a `TestableCopilotAgent` subclass that overrides `_resumeSession` to splice in a fake session implementing the minimal `IFakeAgentSession` interface (`send`, `getMessages`, `dispose`). Both `_resumeSession` and `_resolveSessionWorkingDirectory` are `protected` on `CopilotAgent` for this purpose. This is what makes it possible to write tests that exercise the full path through `sendMessage` and `getSessionMessages` without spinning up the real SDK.

Tests under `src/vs/platform/agentHost/test/node/` have two hygiene rules that are easy to trip on:

- Do not import from `'path'`. Use `URI.joinPath(...)` and string-concat against `os.tmpdir()` instead. The repo lint blocks the `path` import.
- Do not use `as unknown as T` style assertions. Blocked by `local/code-no-dangerous-type-assertions`. If a generic helper signature would force one, refactor to a non-generic signature with a narrow type alias and a single safe cast inside the helper after a runtime discriminant check.

Run via `npm run test-node -- --grep <pattern>`. Do not use `scripts/test.sh` for these focused node tests; it depends on Electron and crashes outside an interactive session.

## Debt & gotchas

- **gotcha** (2026-04-19, copilotAgent.ts:prependAnnouncementToFirstAssistantMessage) - the restore path for session announcements skips messages with `parentToolCallId` so the prepend lands on the first top-level assistant message. If you change this to "first assistant message", the announcement gets buried inside a subagent's history and disappears from the parent turn. Keep the `!m.parentToolCallId` filter.
- **gotcha** (2026-04-19, copilotAgent.ts:sendMessage worktree announcement) - the live-path "first turn" announcement is intentionally in-process only (`_pendingFirstTurnAnnouncements` Map). It is lost if the agent process restarts between worktree creation and the first user prompt. That window is acceptable to lose because the restore path covers every reopen once any reply exists. Do not add a DB-backed "emitted" flag to "fix" this; we tried and reverted (see `changes/2026-04-19-worktree-progress-message/`).
- **gotcha** (2026-04-19, agentService.ts:IAgentDeltaEvent) - the field is `content`, not `delta`. The event's name makes `delta` a tempting typo.
- **gotcha** (2026-04-19, copilotAgent.test.ts) - tests under `src/vs/platform/agentHost/test/node/` cannot `import 'path'`. Use `URI.joinPath` + `os.tmpdir()`, and refactor generic helpers to a non-generic signature with a single discriminant-checked cast inside.
- **gotcha** (2026-04-20, copilotAgent.ts:listSessions / _listModels) - both methods MUST throw `AHP_AUTH_REQUIRED` via `_ensureClient()` when `_githubToken` is unset. Do not short-circuit with `return []`: that violates the AHP `required: true` contract and breaks consumers that cache the first response. The renderer-side `authenticationPending` autorun is the natural retry trigger after auth settles.
- **gotcha** (2026-04-20, copilotAgent.ts:id + getDescriptor) - the agent's id and descriptor `provider` are `'copilotcli'`, not `'copilot'`. They were renamed so the agent advertises the same name the UI uses. There is no longer any alias map / "well-known agent type" indirection.
- **gotcha** (2026-04-20, copilotAgent.test.ts) - when renaming `CopilotAgent.id`, audit hardcoded literals in tests under `src/vs/platform/agentHost/test/node/`, including `protocol/toolApprovalRealSdk.integrationTest.ts`. `AgentSession.uri('copilot', ...)` constructions are not type-checked, and the real-SDK file is gated on `AGENT_HOST_REAL_SDK=1`, so stale provider ids can sit broken indefinitely.
- **gotcha** (2026-04-21, updated 2026-04-22, package.json:@github/copilot) - the root `package.json` and `remote/package.json` versions of `@github/copilot` should track `extensions/copilot/package.json`. The Copilot extension ships with VS Code and is exercised by Copilot's own validation, so its pinned version is the known-good baseline. Bump in lockstep with it.
- **gotcha** (2026-04-22, copilotAgent.ts:ICopilotModelInfo + IAgentModelInfo.maxContextWindow) - at `@github/copilot@1.0.34` the synthetic `auto` router model is returned by `listModels()` with `capabilities: {}`. `ICopilotModelInfo` intentionally wraps the SDK model shape with optional `capabilities`, `limits`, `supports`, and `max_context_window_tokens`; `_listModels` should `.map` and pass `auto` through with `maxContextWindow: undefined` rather than dropping it.
- **gotcha** (2026-04-21, copilotAgent.ts:_refreshModels) - the `try { await _listModels() } catch { _models = [] }` block silently swallows every error, not just `AHP_AUTH_REQUIRED`. SDK schema mismatches, network errors, or throws inside `_listModels` all produce an empty model list in the UI. The real-SDK `listModels returns well-shaped model entries after authenticate` integration test is the safety net.

## Related

- [agent-host-topology](./agent-host-topology.md) - where provider-level listing work fits in the Agent Host architecture.
- [agent-host-protocol](./agent-host-protocol.md) - why ownership filtering is provider persistence, not a protocol change.
- [agent-host-session-handler](./agent-host-session-handler.md) - downstream turn and chat integration after a session is selected.
- [copilot-extension-host-cli](./copilot-extension-host-cli.md) - extension-host CLI reference points and parity gaps.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) - permission callbacks and session-state auto-approval.
- [copilot-sdk-shells](./copilot-sdk-shells.md) - managed shell tools.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) - SDK tool display and command rewriting.

## Changelog

- **2026-04-24** - 4b6403a3ab - split extension-host CLI parity, permissions, shell tools, and tool display details into focused docs; trimmed this doc back to provider lifecycle, ownership, authentication, metadata, announcements, and provider-level tests.
- **2026-04-22** - d6e5c5227d - bumped `@github/copilot` from `^1.0.28` to `^1.0.34`; added `ICopilotModelInfo` wrapper interface with optional `capabilities`/`limits`/`supports`/`max_context_window_tokens`, made `IAgentModelInfo.maxContextWindow` optional, and switched `_listModels` to `.map` so the synthetic `auto` model surfaces with `maxContextWindow: undefined` instead of throwing or being dropped.
- **2026-04-21** - 4da62d3b09 - added gotchas for: (1) `package.json` / `remote/package.json` `@github/copilot` version should track `extensions/copilot/package.json`; (2) `_refreshModels` swallows all throws, so the real-SDK `listModels` integration test is the safety net for SDK schema drift; (3) hardcoded provider id literals in `protocol/toolApprovalRealSdk.integrationTest.ts` can sit broken because the file is env-gated.
- **2026-04-21** - 7bc767483b - added coexistence paragraph to Session Ownership section explaining how the database-existence gate pairs with the extension provider's `getSessionOrigin()` filter.
- **2026-04-20** - d05eca7455 - added Authentication contract section documenting that `listSessions` and `_listModels` throw `AHP_AUTH_REQUIRED` via `_ensureClient()` when no token.
- **2026-04-20** - 00f882a16c - renamed `CopilotAgent.id` and the descriptor `provider` from `'copilot'` to `'copilotcli'`; documented why on-disk DB keys do not require migration.
- **2026-04-19** - adc4f6e17e - documented the worktree-creation session announcement, `copilot.worktree.branchName` metadata key, full lifecycle testing seam, and test/node hygiene rules.
- **2026-04-17** - 9364e338cc - initial entry documenting CopilotAgent SDK session filtering, database-backed ownership, metadata keys, and focused test seams.
