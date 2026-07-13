# Avoid Agent Host worktree path collisions

**Date:** 2026-07-13
**VS Code branch:** roblou/agents/avoid-worktree-exists-error
**VS Code SHA at finalize:** 15f7089591
**PR:** [#325528](https://github.com/microsoft/vscode/pull/325528)

## What was done

New Copilot Agent Host worktree sessions now treat an existing target directory as a naming collision instead of passing it to `git worktree add` and failing with "already exists". `CopilotBranchNameGenerator` checks a bounded sequence of candidates against both Git branches and their derived worktree paths, including fallback names, and leaves orphaned directories untouched.

Candidate selection and worktree creation are serialized per repository so two concurrent sessions cannot both observe the same candidate as free. Failed branch-existence probes remain conservative collisions. Regression tests cover orphaned paths, repeated and fallback collisions, exact candidate exhaustion, failed branch probes, and concurrent same-repository creation.

## Key decisions

- Resolve collisions by choosing another branch/path pair rather than deleting, reusing, or guessing ownership of an existing directory.
- Keep collision policy in the branch-name generator via a provider-supplied predicate, while the provider owns the branch/path checks and the creation critical section.
- Serialize per repository, not globally, so unrelated repositories can create worktrees concurrently.
- Bound candidate search to exactly 100 checked names and fail explicitly if none is available.

## What went wrong or was misunderstood

- The first implementation checked the initial target path but returned unchecked secondary/fallback candidates and left a TOCTOU window between probing and `git worktree add`. Independent review caught both gaps. — **prevented by:** the new `gotcha:` in `copilot-agent-provider` requiring all candidates to check branch plus path and requiring selection/creation to remain in one per-repository critical section.
- The initial refactor dropped the existing conservative `.catch(() => true)` behavior around `branchExists`, so a transient Git probe failure aborted materialization instead of moving to another candidate. PR review caught the regression. — **prevented by:** the same `gotcha:` now records failed branch probes as collisions.
- The collision loop's diagnostic claimed 100 attempts even though one fallback path entered the loop at index 2 and checked fewer loop candidates. — **prevented by:** the provider doc now describes a single bounded candidate sequence, and the regression test snapshots the exact count and endpoints.
- The provider doc still described an obsolete `getCopilotWorktreeBranchName` shape that always appended the short session id, while current code prefers the bare hint and adds suffixes only on collision. — **prevented by:** the session-announcements body now documents the actual generator and candidate order.
- After review comments arrived, they were initially reported without being acted on until the user prompted again. — **prevented by:** this summary; review-feedback turns should continue through fix, verification, reply, and thread resolution unless the user asks only for triage.

## What we learned

- Branch uniqueness and filesystem-path uniqueness are one allocation problem for worktree creation; checking only one is insufficient.
- `SequencerByKey` is a simple fit for repository-scoped allocation without unnecessarily serializing all sessions.
- macOS Chat Sandbox smoke tests can repeatedly fail on the unrelated `allowRead` home-directory assertion; rerunning the failed job succeeded without source changes.

## Doc updates

- `docs/copilot-agent-provider.md` — corrected branch-name derivation and collision behavior, documented per-repository sequencing and bounded candidate search, added the collision/creation `gotcha:`, updated Covers, and added a changelog entry.
- `index.md` — expanded the provider description and Covers list to include collision-safe worktree naming and `copilotBranchNameGenerator.ts`.
- No debt entries were added or removed.
