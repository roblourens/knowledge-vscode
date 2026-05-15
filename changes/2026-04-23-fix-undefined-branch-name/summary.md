# Wire agent-host git metadata into the agents-app changes view via `_meta.git`

**Date:** 2026-04-25
**VS Code branch:** roblou/agents/agent-host-git-metadata
**VS Code SHA at finalize:** 8e9b24cedf
**PR:** [#312543](https://github.com/microsoft/vscode/pull/312543)

## What was done

Agent-host sessions in the agents app weren't showing a branch name in the changes view, and the blue "Merge changes" / "Create pull request" skill buttons stayed hidden because the underlying `workspace.repositories[0]` had no git fields. This change computes that git state server-side in the agent-host process and propagates it to clients through the AHP `_meta` slot on `SessionState`.

Server side: `IAgentHostGitService.getSessionGitState(workingDirectory)` shells out to `git` to gather branch / base branch / GitHub-remote-ness / ahead / behind / uncommitted counts. `AgentService` calls `_attachGitState` on session create, restore, lazy subscribe-without-meta, and turn-complete; that writes the result to `state._meta.git` via `setSessionMeta(withSessionGitState(...))`, which dispatches a normal `SessionMetaChanged` reducer action (no new protocol commands needed).

Client side: `AgentHostSessionAdapter.setMeta` reads it back via `readSessionGitState(meta)` and rebuilds the workspace through `buildAgentHostSessionWorkspace`, fanning the git fields onto `workspace.repositories[0]`. `baseBranchProtected` is derived client-side against the user's `git.branchProtection` patterns. The Sessions app changes view (`changesViewModel.ts`) now picks them up with `?? workspaceRepository?.X` fallbacks alongside the pre-existing list-controller `metadata?.X` path that Cloud uses.

A new `SESSION_META_GIT_KEY` slot, `ISessionGitState` interface, and `readSessionGitState` / `withSessionGitState` helpers live in `sessionState.ts`. Future server-computed well-known per-session metadata can use the same pattern without protocol churn.

## Key decisions

- **Server-computed, not client-computed.** The agent host already has the working directory and a child-process facility; the workbench changes-view layer doesn't own a `git` invocation surface for agent-host worktrees. Computing server-side keeps the workbench reactive to a single source of truth.
- **Use the generic `_meta` slot, not a typed `git` field on `SessionState`.** `_meta` is a `Record<string, unknown>` with well-known string keys and is the right pattern for server-computed, optional, and conceptually-extensible per-session metadata. Adding more well-known keys (e.g. `_meta.someOtherDomain`) follows the same recipe.
- **Two write paths through `AgentService`.** `_attachGitState` runs on session create / restore / subscribe-with-no-meta-yet / `onTurnComplete`. The subscribe path is the lazy backfill for sessions that pre-date the feature. Turn-complete refreshes after every successful turn — since most user-driven git state changes (commits, branch switches) happen during a turn, this is the natural cadence.
- **Dedupe at the source.** `_attachGitState` skips `setSessionMeta` if the new git state `equals` the current one — turn-complete fires on every turn, and most turns don't change git state.
- **Defer the architectural cleanup of the parallel metadata paths.** Cloud uses `IAgentSessionListController._buildMetadata` → `IAgentSession.metadata`. Agent-host uses `_meta.git` → `setMeta` → `workspace.repositories[0]`. Unifying them is desirable but no other VS Code consumer reads these git fields today, so the duplication has no behavioral payoff. Recorded as debt.

## What went wrong or was misunderstood

- **Constructor dep was made optional and shipped the entire feature as a silent no-op.** `AgentService` was given `_gitService?: IAgentHostGitService`, ostensibly to avoid updating call sites, and `_attachGitState` quietly returned when it was `undefined`. Both production entry points (`agentHostMain.ts` *and* `agentHostServerMain.ts`) needed to wire it; only one was updated, and the optional type let TypeScript stay silent about the other. The user reported "still no branch" repeatedly across multiple log files before I noticed `hasGitService=false` in the logs. — **prevented by:** new gotcha in `agent-host-sessions-providers.md` + the existing learning in `.github/instructions/agentHostTesting.instructions.md` ("constructor deps must be required").
- **Claimed the feature was wired end-to-end without verifying it.** Several "I confirmed metadata reaches the client" assertions during the debug rounds were unfounded — `_meta.git` was never reaching the client because `_attachGitState` was a no-op. The user had to push back multiple times. — **prevented by:** the same constructor-dep gotcha (which was the root cause of every "I verified it" claim being false), plus a workflow norm of "don't claim wired-up unless I personally observed the data crossing the wire."
- **Missed the parallel `IAgentSession.metadata` path early.** The Cloud agent populates the same conceptual git fields via `IAgentSessionListController._buildMetadata`, and `changesViewModel.ts` was already reading `metadata?.branchName`. I treated that as a Cloud-only oddity and added a parallel path through `workspace.repositories[0]` instead of routing agent-host through the same `_buildMetadata` shape. The user surfaced this late in review and we kept the parallel paths (with fallback in `changesViewModel.ts`) as recorded debt rather than refactoring mid-PR. — **prevented by:** new debt entry in `agent-host-sessions-providers.md` + cross-cutting pointer in `index.md` so the next person touching changes view sees it before adding a third path.
- **Scope crept to non-worktree sessions.** I assumed branch display was wanted everywhere and surfaced it for non-worktree agent-host sessions; the user pushed back and the change was reverted. — **prevented by:** this summary (no doc-level rule worth recording).
- **Late merge-conflict / review-feedback rounds.** A merge conflict landed in `.ahp-version` and three Copilot review comments needed addressing (missing `?? workspaceRepository?.baseBranchName` fallback, an unobvious dependency-read in `changesView.ts`, and a missing dedupe in `_attachGitState`). All addressed cleanly. — **prevented by:** nothing structural; this is the normal late-PR shape and the dedupe debt is now an explicit gotcha.

## What we learned

- The `_meta` slot is a clean way to ship server-computed, optional, well-known per-session metadata without expanding the typed `SessionState` surface or adding new protocol commands. The well-known-key pattern (`SESSION_META_GIT_KEY` + `read*` / `with*` helpers) keeps each consumer narrow.
- The agents-app changes view consumes session metadata through **two** paths, and that distinction is invisible from the client-rendering code unless you look for it. Per-domain metadata that the changes view needs to render must be plumbed through whichever path the originating session host already uses.
- `_attachGitState` runs on every `onTurnComplete`, so dedup matters; equality on the value (via `equals` from `vs/base/common/objects`) is sufficient and avoids spurious `SessionMetaChanged` actions.

## Doc updates

- **agent-host-sessions-providers.md** — added "Surfacing session `_meta.git` to `workspace.repositories[0]`" section; added gotcha (constructor deps must be required); added debt (parallel list-controller vs sessions-provider metadata paths to changes view); added debt (per-session git-probe lifecycle).
- **agent-host-protocol.md** — documented `SessionState._meta` and the well-known `git` key (`SESSION_META_GIT_KEY`, `ISessionGitState`, `readSessionGitState`, `withSessionGitState`); added changelog entry.
- **index.md** — added cross-cutting debt pointer about parallel session-metadata paths, pointing to `agent-host-sessions-providers.md`.
