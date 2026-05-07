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

`restoreSession(...)` can now resume a known Agent Host-owned session directly from its URI / database metadata. It does not require a successful `listSessions()` catalog pass first, which matters for reopening a stored session when the SDK list is unavailable, stale, or filtered by a different catalog view.

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
- `copilot.worktree.branchName`, `copilot.worktree.path`, `copilot.worktree.repositoryRoot` - set together when isolation is `worktree`. The branch name is used by the restore path of the [session announcements](#session-announcements-worktree-creation) feature to reconstruct the "Created isolated worktree for branch X" message when a session is reopened. All three together are required by the [archive lifecycle](#archive-lifecycle-worktree-cleanup) — without the path and repository root, the provider has no way to find the on-disk worktree from a cold process.

Use `tryOpenDatabase()` for read-only checks that must not create session data. Use `openDatabase()` only on paths that intentionally create or update Agent Host-owned session data.

## Archive lifecycle (worktree cleanup)

When a worktree-isolated session is archived, `CopilotAgent.onArchivedChanged(session, true)` removes the on-disk worktree but leaves the git branch intact. Unarchiving (`onArchivedChanged(session, false)`) recreates the worktree from the preserved branch via `git worktree add`. The trigger is wired generically: `agentSideEffects.ts` `case ActionType.SessionIsArchivedChanged` calls the optional `IAgent.onArchivedChanged?(session, isArchived)` after persisting the archive flag, and any provider can opt in by implementing the hook.

The whole body is sequenced through the existing `_sessionSequencer: SequencerByKey<string>` so it cannot race with `disposeSession` or in-flight turns. The implementation reads `copilot.worktree.{branchName,path,repositoryRoot}` via `tryOpenDatabase()`. Skip behavior:

- **Archive skips** (worktree left on disk): metadata absent → no-op (see gotcha below); worktree directory already gone → drop the in-memory `_createdWorktrees` entry only; branch missing → log and bail (we wouldn't be able to recreate); uncommitted changes in the worktree → log `uncommitted-changes` and bail. The dirty-skip is the safety net in lieu of an auto-commit pass.
- **Unarchive skips**: metadata absent → no-op; worktree already exists → no-op; branch missing → log and bail.

The git helpers used here live on `IAgentHostGitService`: `branchExists`, `hasUncommittedChanges`, `addExistingWorktree`. The first two are also worth using anywhere else that needs the same checks; `addExistingWorktree` is `git worktree add <path> <branch>` (no `-b`), distinct from the existing `addWorktree` which creates a new branch.

Auto-commit at end of turn is **out of scope** for this feature. EH CLI has a `handleRequestCompleted` hook that can auto-commit, but in practice it is off by default and we do not mirror it.

## Session announcements (worktree creation)

When `_resolveSessionWorkingDirectory` creates an isolated worktree, the user should see a "Created isolated worktree for branch `X`" message at the top of the very first response, both live as the model is replying and on every subsequent reopen of the session.

The branch name itself is derived **server-side from the first user prompt**, not sent by the client. `_materializeProvisional(sessionId, prompt)` runs on the first `sendMessage` and forwards the prompt to `_resolveSessionWorkingDirectory(config, sessionId, prompt)`, which calls `getCopilotBranchNameHintFromMessage(prompt)` to slug the message (NFKD-normalize, lowercase, strip non-`[a-z0-9]`, drop empties, take first 8 words, cap at 48 chars; returns `undefined` for punctuation-only/empty input). The hint is fed to `getCopilotWorktreeBranchName(sessionId, hint)` which produces `agents/<hint>-<sessionId8>` (or `agents/<sessionId>` when the hint is empty). This is why the eager-create path on the workbench can dispatch `SessionConfigChanged` without `createSession` and not need to forward a `branchNameHint`: the AH derives it from the prompt that's already in hand at materialization time.

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
- **gotcha** (2026-04-22, updated 2026-04-28, copilotAgent.ts:ICopilotModelInfo + IAgentModelInfo.maxContextWindow) - at `@github/copilot@1.0.34` and still at `1.0.38` the synthetic `auto` router model is returned by `listModels()` with `capabilities: {}`. `ICopilotModelInfo` intentionally wraps the SDK model shape with optional `capabilities`, `limits`, `supports`, and `max_context_window_tokens`; `_listModels` should `.map` and pass `auto` through with `maxContextWindow: undefined` rather than dropping it.
- **gotcha** (2026-04-29, copilotAgent.ts:_readWorktreeMetadata) - if `copilot.worktree.path` or `copilot.worktree.repositoryRoot` is missing (sessions created before those keys were persisted), both `_cleanupWorktreeOnArchive` and `_recreateWorktreeOnUnarchive` early-return and leave the worktree on disk untouched. Do not "fix" this by deriving the worktree path from `copilot.workingDirectory` and reversing the `<repoBasename>.worktrees/<wt>` convention to recover the repository root: the derivation works for the common case, but if the user has a non-standard repo layout the inverse can produce a wrong path and we would delete a worktree we cannot recreate. Skipping is the safer default — the worktree stays on disk and the user is no worse off than before the feature existed.
- **gotcha** (2026-04-29, copilotAgent.ts:onArchivedChanged) - the archive cleanup path **skips on uncommitted changes** (`hasUncommittedChanges(worktreePath)` true → log and bail). This is intentional: there is no auto-commit pass before cleanup, so silently destroying user work would be a regression. EH CLI has the same protection. Do not remove this guard without first wiring an auto-commit/checkpoint flow.
- **gotcha** (2026-04-21, copilotAgent.ts:_refreshModels) - the `try { await _listModels() } catch { _models = [] }` block silently swallows every error, not just `AHP_AUTH_REQUIRED`. SDK schema mismatches, network errors, or throws inside `_listModels` all produce an empty model list in the UI. The real-SDK `listModels returns well-shaped model entries after authenticate` integration test is the safety net.
- **gotcha** (2026-05-04, copilotAgent.ts:_sessions) — `_sessions` is keyed by **root** session IDs only (e.g. `'root'` for `copilot:/root`). Subagent URIs (`copilot:/root/subagent/tc1`) are never keys. Any code that needs the backing `CopilotAgentSession` from a subagent URI MUST walk the full ancestry to the root: `let t = uri; let p; while ((p = parseSubagentSessionUri(t))) t = p.parentSession;`. A single `parseSubagentSessionUri` call is insufficient for depth-2+ nested subagents; it produces an intermediate URI that is not in `_sessions`, and the lookup silently returns `undefined`. Both `onClientToolCallComplete` and `getSessionMessages` had this bug before PR [#313924](https://github.com/microsoft/vscode/pull/313924).
- **gotcha** (2026-05-07, copilotAgent.ts:getCopilotBranchNameHintFromMessage / _materializeProvisional) — the worktree branch name hint is derived **on the agent host** from the first user prompt, not sent by the client. Earlier code shipped a `SessionConfigKey.BranchNameHint` config key and a client-side `getAgentHostBranchNameHint` helper; both were removed in PR [#315065](https://github.com/microsoft/vscode/pull/315065) once the prompt was plumbed through `sendMessage` → `_materializeProvisional` → `_resolveSessionWorkingDirectory`. Do not reintroduce a client-side hint or a `branchNameHint` config property — the AH already has the prompt at materialization time, and pushing the slugger to the client would force every transport (local, SSH, tunnel, web) to mirror the same algorithm and stay in lockstep with it. If the slug rules need to change, change them in `getCopilotBranchNameHintFromMessage` only.

## Related

- [agent-host-topology](./agent-host-topology.md) - where provider-level listing work fits in the Agent Host architecture.
- [agent-host-protocol](./agent-host-protocol.md) - why ownership filtering is provider persistence, not a protocol change.
- [agent-host-session-handler](./agent-host-session-handler.md) - downstream turn and chat integration after a session is selected.
- [copilot-extension-host-cli](./copilot-extension-host-cli.md) - extension-host CLI reference points and parity gaps.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) - permission callbacks and session-state auto-approval.
- [copilot-sdk-shells](./copilot-sdk-shells.md) - managed shell tools.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) - SDK tool display and command rewriting.

## Changelog

- **2026-05-07** — d116f50c33 — branch-name hint for `worktree`-isolated sessions is now derived server-side from the first user prompt (`getCopilotBranchNameHintFromMessage`), plumbed through `sendMessage` → `_materializeProvisional(sessionId, prompt)` → `_resolveSessionWorkingDirectory(config, sessionId, prompt?)`. Removed `SessionConfigKey.BranchNameHint` and the workbench-side `getAgentHostBranchNameHint` helper. Added a gotcha not to reintroduce client-side hint plumbing. PR [#315065](https://github.com/microsoft/vscode/pull/315065).
- **2026-05-04** — 81095cbaba — added two gotchas: (1) `_sessions` is keyed by root session IDs only — any lookup from a subagent URI must walk the full ancestry to root, not stop at one `parseSubagentSessionUri` call; (2) `_maybeEvictIdleSession` must target the root so idle state doesn't leak when only a deeply-nested subagent URI unsubscribes. Both bugs fixed in PR [#313924](https://github.com/microsoft/vscode/pull/313924).
- **2026-05-01** — b2e6267136 — reconciliation: documented direct restore without a prior SDK catalog list after `317392ea7d46`; archive/worktree lifecycle prose from `2c0d520761` stayed accurate across `c7dadb49e4f6` cleanup and the later Copilot/Claude-adjacent commits did not change this provider's architectural contract.
- **2026-04-29** - 2c0d520761 - added Archive lifecycle section: `IAgent.onArchivedChanged?` hook, `CopilotAgent` archive/unarchive worktree cleanup via new `branchExists`/`hasUncommittedChanges`/`addExistingWorktree` helpers on `IAgentHostGitService`, sequenced through `_sessionSequencer`, with skip-on-dirty / skip-on-missing-branch / skip-on-missing-metadata guards. Added `copilot.worktree.path` and `copilot.worktree.repositoryRoot` metadata keys. Added two gotchas (don't derive missing metadata; keep the dirty-skip guard). PR [#313393](https://github.com/microsoft/vscode/pull/313393).
- **2026-04-28** - 5e0eb8ff17 - bumped `@github/copilot` from `^1.0.34` to `^1.0.38` (root + `remote/`) to track the version pinned in `extensions/copilot/package.json`. No consumer-side changes: the `ICopilotModelInfo` wrapper still absorbs the synthetic `auto` model shape and the real-SDK `listModels` test passes unchanged. `@github/copilot-sdk` stays at `^0.2.2`.
- **2026-04-24** - 4b6403a3ab - split extension-host CLI parity, permissions, shell tools, and tool display details into focused docs; trimmed this doc back to provider lifecycle, ownership, authentication, metadata, announcements, and provider-level tests.
- **2026-04-22** - d6e5c5227d - bumped `@github/copilot` from `^1.0.28` to `^1.0.34`; added `ICopilotModelInfo` wrapper interface with optional `capabilities`/`limits`/`supports`/`max_context_window_tokens`, made `IAgentModelInfo.maxContextWindow` optional, and switched `_listModels` to `.map` so the synthetic `auto` model surfaces with `maxContextWindow: undefined` instead of throwing or being dropped.
- **2026-04-21** - 4da62d3b09 - added gotchas for: (1) `package.json` / `remote/package.json` `@github/copilot` version should track `extensions/copilot/package.json`; (2) `_refreshModels` swallows all throws, so the real-SDK `listModels` integration test is the safety net for SDK schema drift; (3) hardcoded provider id literals in `protocol/toolApprovalRealSdk.integrationTest.ts` can sit broken because the file is env-gated.
- **2026-04-21** - 7bc767483b - added coexistence paragraph to Session Ownership section explaining how the database-existence gate pairs with the extension provider's `getSessionOrigin()` filter.
- **2026-04-20** - d05eca7455 - added Authentication contract section documenting that `listSessions` and `_listModels` throw `AHP_AUTH_REQUIRED` via `_ensureClient()` when no token.
- **2026-04-20** - 00f882a16c - renamed `CopilotAgent.id` and the descriptor `provider` from `'copilot'` to `'copilotcli'`; documented why on-disk DB keys do not require migration.
- **2026-04-19** - adc4f6e17e - documented the worktree-creation session announcement, `copilot.worktree.branchName` metadata key, full lifecycle testing seam, and test/node hygiene rules.
- **2026-04-17** - 9364e338cc - initial entry documenting CopilotAgent SDK session filtering, database-backed ownership, metadata keys, and focused test seams.
