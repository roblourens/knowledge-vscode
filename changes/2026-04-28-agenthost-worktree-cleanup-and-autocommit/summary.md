# Agent Host worktree cleanup on archive / unarchive

**Date:** 2026-04-29
**VS Code branch:** roblou/agents/cleanup-agenthost-worktrees
**VS Code SHA at finalize:** 2c0d520761
**PR:** [#313393](https://github.com/microsoft/vscode/pull/313393)

## What was done

Mirrored the EH CLI's `cleanupWorktreeOnArchive` / `recreateWorktreeOnUnarchive` in the Agent Host. New optional `IAgent.onArchivedChanged?(session, isArchived)` hook, dispatched from `agentSideEffects.ts` after persisting the archive flag. `CopilotAgent` implements it: archive removes the on-disk worktree (preserving the branch); unarchive `git worktree add`s it back from the preserved branch. New `branchExists`, `hasUncommittedChanges`, `addExistingWorktree` helpers on `IAgentHostGitService`. New persisted metadata: `copilot.worktree.path` and `copilot.worktree.repositoryRoot` (alongside the existing `copilot.worktree.branchName`) so the cleanup can run from a cold process. All sequenced through the existing `_sessionSequencer` to avoid races with `disposeSession` and in-flight turns.

Auto-commit at end of turn (EH CLI's `handleRequestCompleted`) was explicitly **out of scope** — it's off by default in EH CLI in practice, and we did not want to silently destroy user work without it. Until/unless we wire one, the archive cleanup path skips when the worktree has uncommitted changes.

## Key decisions

- **Skip on uncommitted changes**, log the reason, do not destroy work — safer default given there's no auto-commit fallback in scope.
- **Mirror the full archive lifecycle** — both cleanup-on-archive and recreate-on-unarchive — not just one side.
- **Trigger via the existing `SessionIsArchivedChanged` action** rather than a new protocol message; no AHP wire change.
- **Generic `IAgent` hook**, not Copilot-specific. Other future providers can opt in by implementing `onArchivedChanged?`.
- **Separate `addExistingWorktree`** rather than overloading `addWorktree` with a `{ createBranch?: boolean }` option — clearer call sites and easier to mock.
- **Skip cleanup if metadata is missing** (sessions created before `copilot.worktree.{path,repositoryRoot}` were persisted) rather than derive the worktree path from `copilot.workingDirectory` and reverse the worktrees-root naming convention to recover the repository root. The derivation works for the common layout but can produce a wrong repo path for non-standard layouts — and deleting a worktree we cannot recreate would be a regression.

## What went wrong or was misunderstood

- **Initial fix for legacy sessions over-engineered the wrong thing.** The first round of code review ("for old sessions that didn't persist `_META_WORKTREE_PATH`, I can delete the worktree but not restore it") was answered with a derivation: fall back to `copilot.workingDirectory` for the worktree path and reverse `<repoBasename>.worktrees/<wt>` to recover the repo root. The user pushed back: if you can't restore reliably, don't delete. That made the safer fix obvious — early-return when metadata is missing, leave the worktree on disk untouched. **Prevented by:** new `gotcha` on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) explicitly calling out that when restore depends on metadata you don't have, you must skip rather than guess; and a `gotcha` on the dirty-skip guard for the same reason at the other end of the lifecycle. General principle for future agent-host destructive operations: **derivation is acceptable for advisory paths but not for destructive ones**.
- **`AgentHostGitService._runGit` returns `undefined` on non-zero exit** (without `throwOnError: true`). Easy to assume it throws on git errors and write `try/catch` around it; the right pattern for "does this ref/path exist?" is to `await _runGit(...)` and check for `undefined`. **Prevented by:** existing `getDefaultBranch` usage was the right model; callout in `tasks.md` discoveries (now baked into the change summary). Worth promoting to a `gotcha` on a future `agentHostGitService` doc when one exists.
- **`_resolveSessionWorkingDirectory` is the only place that populates the in-memory `_createdWorktrees` map.** Persisted metadata is now the source of truth for archive/unarchive after a process restart; the in-memory map is a fast path only. Easy to break by adding writes that update one and not the other. **Prevented by:** the new metadata keys are written in the same metadata block as `branchName`, so the three move together at the only producer.

## What we learned

- **`IAgent` is a good extension point for cross-provider lifecycle hooks.** Adding `onArchivedChanged?` as optional and dispatching from the side-effects layer kept the wiring generic; future providers (Claude SDK, etc.) can opt in without provider-specific glue in `agentSideEffects.ts`.
- The `_sessionSequencer: SequencerByKey<string>` in `CopilotAgent` is the right place to land any new lifecycle work that needs to serialize against `disposeSession` and turn execution. Adding behaviour through it is structural — no separate race tests needed.

## Doc updates

- [copilot-agent-provider.md](../../docs/copilot-agent-provider.md):
  - New **Archive lifecycle (worktree cleanup)** section.
  - Metadata section updated: `copilot.worktree.{branchName,path,repositoryRoot}` listed together; called out as required-as-a-set for the archive lifecycle.
  - Added two `gotcha` entries: don't derive missing worktree metadata; keep the dirty-skip guard.
  - Changelog entry.
- [copilot-extension-host-cli.md](../../docs/copilot-extension-host-cli.md):
  - "Parity gaps" worktree paragraph: noted archive cleanup is now mirrored; auto-commit/checkpoint remains.
  - Narrowed the existing `debt:` entry on `_resolveSessionWorkingDirectory` from "no archive lifecycle and no auto-commit" to just "no auto-commit/checkpoint", with a pointer to the new section.
  - Changelog entry.
