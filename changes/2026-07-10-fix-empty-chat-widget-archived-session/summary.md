# Fix empty chat widget when opening an archived worktree agent session

**Date:** 2026-07-10
**VS Code branch:** agents/fix-empty-chat-widget-archived-session
**VS Code SHA at finalize:** 4c9acc2444
**PR:** [#324341](https://github.com/microsoft/vscode/pull/324341) · Issue [#319244](https://github.com/microsoft/vscode/issues/319244)

## What was done

Opening a recently-archived, worktree-isolated Copilot session showed an **empty chat widget** with no transcript and no error. Archiving deletes the session's git worktree (keeping the branch); on resume the Copilot SDK requires the working directory to exist to bring the session up, so both `resumeSession` and its `createSession` fallback failed and the session restored with 0 turns. The failure was swallowed at two layers, so nothing was shown.

The fix spans four layers:

1. **Read-only enforcement (agent-agnostic).** `AgentSideEffects._sendTurnMessage` rejects turns to a read-only chat via `isChatReadOnly(chatState?.interactivity, sessionArchived)`, computed from the orchestrator's own state (folds the session archived flag into the chat's effective interactivity). Shared helpers `effectiveChatInteractivity` / `isChatReadOnly` live in `common/state/sessionState.ts`. This also closes a pre-existing gap where turns to read-only subagent chats were never enforced.
2. **Resume working-directory repair (`CopilotAgent._ensureResumeWorkingDirectory`).** Archived → resume against the persisted `repositoryRoot` for history only; live (non-archived) with a deleted worktree → recreate it from the persisted branch via the shared `_recreateWorktree` (also used by unarchive); otherwise throw the exported `SessionWorkingDirectoryMissingError` (carrying a `reason`). `git worktree add` gained `-f` to handle the deleted-but-still-registered case. Archived flag read via `_isSessionArchived` using the new shared `AH_META_IS_ARCHIVED_DB_KEY` / `AH_META_IS_DONE_DB_KEY` constants.
3. **UI (agent window).** `effectiveChatInteractivity` derivation forces every non-hidden chat read-only when archived; `SessionReadOnlyBanner` shows an archived-specific message with an inline **Restore** action wired to the extracted `UNARCHIVE_SESSION_COMMAND_ID`.
4. **Error surfacing (editor-window handler).** `agentHostSessionHandler` rethrows an `Error` subscription value and, on hard load failure, renders a system-initiated request + `errorDetails` response showing the real error via `unwrapSessionLoadErrorMessage`, instead of a blank session.

## Key decisions

- **Read-only is derived, never stored.** Archived is already session-level truth (`SessionStatus.IsArchived`); folding it into effective interactivity on read (in the host enforcement and the UI) avoids denormalizing the same fact onto every chat's protocol `interactivity`. ("Put truth at the layer that owns it.")
- **Enforce on interactivity, not on archived directly.** Keying the host guard off `isChatReadOnly` makes one check cover subagent read-only chats and archived sessions alike, rather than special-casing archived.
- **Live vs. archived repair diverge.** A live session's missing worktree is *recreated* (preserve isolation); only an archived session degrades to the repo root (history only, and it can't run turns anyway). Never silently run a live session against the source repo.
- **Fail explicitly.** When the directory can't be resolved, throw a typed error with a reason rather than returning empty — and surface that reason to the UI. ("Fail explicitly for contract violations.")
- **Shared constants over string literals** for the archived-flag metadata keys, matching the existing `AH_META_WORKSPACELESS_DB_KEY` pattern.

## What went wrong or was misunderstood

- **Initially treated "missing worktree" as archived-only** and made resume fall back to the source repo unconditionally. Rob caught that a *live* session's deleted worktree must be recreated, or isolation is silently lost and the agent could run against the user's working tree. — **prevented by:** doc body ([resume working-directory repair](../../docs/copilot-agent-provider.md#resume-working-directory-repair)) + a `gotcha:` on copilot-agent-provider.
- **`git worktree add` (no `-f`) fails on a deleted-but-registered worktree** (`fatal: '<path>' is a missing but already registered worktree`) — the recreation path failed exactly where it was needed. Only surfaced from Rob's runtime log. — **prevented by:** `gotcha:` on copilot-agent-provider (`addExistingWorktree`).
- **Claimed "there's no read-only message in the UI"** — wrong; an existing `SessionReadOnlyBanner` (in `vs/sessions/browser/parts/`, outside the chat-widget area I searched) already renders one. — **prevented by:** doc body on agent-host-sessions-providers documenting the banner + archived derivation.
- **Hardcoded `'isArchived'`/`'isDone'` metadata-key literals** across writer and readers, when the shared-key pattern (`AH_META_WORKSPACELESS_DB_KEY`) already existed and should have been followed. — **prevented by:** Metadata-section doc update on copilot-agent-provider naming the shared constants.
- **The error was swallowed at two layers** (host `getMessages` → `[]`, client hydration catch → empty session), and even after throwing, `_whenSubscriptionHydrated` swallows subscription errors so the thrown value had to be re-checked via `sub.value`. — **prevented by:** doc body on agent-host-session-handler (surfacing load failures) + the `unwrapSessionLoadErrorMessage` note.
- **A bare `'response'` history item is silently dropped** by `chatServiceImpl.loadRemoteSession` if it has no preceding request — the error response needed a system-initiated request to anchor it. Non-obvious rendering precondition. — **prevented by:** the session-handler doc note on the request+response pairing.
- **Environment:** the merge from `origin/main` bumped Node's `.nvmrc` to 24.17.0 and added `@vscode/fs-copyfile`; the session's default Node (24.15.0) failed the preinstall check until switching via fnm. — **prevented by:** this summary (workflow note).

## What we learned

- **This fix does not cover Claude or Codex.** Neither does git worktree isolation, so the archive-deletes-worktree trigger doesn't apply — but both still load an empty chat with no error when a working directory is otherwise missing (reaped scratch dir, deleted project folder): Codex's `getSessionMessages` returns `[]`, Claude passes a stale cwd to `materialize()` unchecked. The agent-agnostic read-only enforcement + UI *do* apply to them; the resume-side repair and error-throwing do not. Recorded as cross-cutting debt.
- **`onArchivedChanged` is optional on `IAgent`:** Copilot and Codex implement it, Claude does not; Codex's implementation just sends an archive RPC (no worktree work).

## Doc updates

- **copilot-agent-provider.md** — new "Resume working-directory repair" section; Archive-lifecycle section updated (`_recreateWorktree` shared helper returning `{ok,reason}`, `git worktree add -f`); Metadata section adds the `AH_META_IS_ARCHIVED_DB_KEY`/`AH_META_IS_DONE_DB_KEY` shared keys + `_isSessionArchived`. Added `gotcha` (worktree add `-f`), `gotcha` (archived-vs-live repair distinction), and `debt` (Claude/Codex parity gap). Changelog entry.
- **agent-host-sessions-providers.md** — new paragraph on archived → read-only derivation (`effectiveChatInteractivity`, `AdditionalChat` `sessionIsArchived` ctor param), the `SessionReadOnlyBanner` + Restore action, and `UNARCHIVE_SESSION_COMMAND_ID`. Changelog entry.
- **agent-host-session-handler.md** — new "Patterns and gotchas" bullet on surfacing hard load failures (system-initiated request + `errorDetails`, `unwrapSessionLoadErrorMessage`, `sub.value` rethrow, request-anchoring precondition). Changelog entry.
- **index.md** — added cross-cutting `debt` pointer: missing-working-directory repair is Copilot-only.
