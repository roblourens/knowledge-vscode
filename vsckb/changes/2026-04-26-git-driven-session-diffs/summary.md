# Git-driven session file diffs for the Agent Host

**Date:** 2026-04-26
**VS Code branch:** roblou/agents/git-driven-diff-reporting
**VS Code SHA at finalize:** b86149ad81
**PR:** [#312632](https://github.com/microsoft/vscode/pull/312632)

## What was done

Replaced the edit-tracking "Branch changes" diff source in the Agent Host with a `git diff`-driven implementation. Previously, the changes view only tracked individual editor saves and missed changes made via terminal commands or external tools. Now `AgentSideEffects._computeGitDrivenDiffs` runs after every turn, shells out to `git diff --raw --numstat -z` against the merge-base of the session's base branch, and publishes the resulting `ISessionFileDiff[]` to the session's `changes` observable.

Key components built:
- `AgentHostGitService.computeSessionFileDiffs` — computes diffs via real git; uses a temp-index dance (`_runWithTempIndex`) to include untracked files without disturbing the real index; sets `COMMAND_HOOK_LOCK=1` for GVFS repos.
- `gitDiffContent.ts` — `buildGitBlobUri` / `parseGitBlobUri` for encoding the "before" content location; `GitBlobFilesystemProvider` that serves the diff editor's "before" pane by running `git show <sha>:<path>`.
- `META_DIFF_BASE_BRANCH` — session-DB key where `CopilotAgent` persists the base branch name at session creation so `AgentSideEffects` can anchor the diff.
- `agentHostDiffs.ts` — `diffsToChanges` (returns `IChatSessionFileChange2[]`) and `diffsEqual` to convert protocol-layer diffs to the sessions-layer type and guard no-op updates.
- Integration tests for `AgentHostGitService` using real git on disk; unit tests for the `AgentSideEffects` git path.

Also refactored `AgentHostGitService` to use `IFileService` and `INativeEnvironmentService` instead of raw `fs/promises` and `os`, and fixed DI injection — `IAgentHostGitService` is now injected via `@IAgentHostGitService` decorator in `AgentSideEffects`, not passed through the options bag.

## Key decisions

- **`IChatSessionFileChange2` not `IChatSessionFileChange`** — the renderer detects deletions by `change.modifiedUri === undefined`. `IChatSessionFileChange` has a required `modifiedUri`; returning it for a deletion forces the (nonexistent) deleted file path into `modifiedUri`. The fix was to always return `IChatSessionFileChange2`, which has a mandatory `uri` field (the row identity) and an optional `modifiedUri` (set to `undefined` for deletions, actual path for modifications/additions).
- **Temp-index for untracked files** — `git diff HEAD` doesn't show untracked files. A throwaway `GIT_INDEX_FILE` seeded from `HEAD` and populated with `git add -A -- :/` lets `git diff --cached <mergeBase>` include those files without touching the real index.
- **`COMMAND_HOOK_LOCK=1`** — mirrors `buildTempIndexEnv` in the extension-host CLI. Without it, GVFS repos hang when the hook lock is held by the outer git operation.
- **Code sharing with extension-host CLI rejected** — the extension side uses `vscode.Uri` + `DiffChange[]` (extension-host types); Agent Host uses `vs/base/common/uri.URI` + `ISessionFileDiff[]` (platform types). A shared intermediate would need two adapters for ~80 lines of parsing logic. Not worth it; Agent Host's version is also more defensive (handles empty repos, GVFS, untracked files more explicitly).
- **`IAgentHostGitService` as required DI dep** — previous session already established the pattern: making a constructor dep optional to silence TypeScript at call sites causes the feature to ship as a runtime no-op. `AgentService` registers `IAgentHostGitService` in a local `ServiceCollection` rather than passing it through the options bag.
- **`IFileService` / `INativeEnvironmentService` instead of raw node modules** — agent host services should use VS Code platform services for testability and consistency, not `fs/promises`/`os` directly.

## What went wrong or was misunderstood

- **Added-file diff broke the diff editor** — the `git-blob:` URI for the "before" side of a new file was constructed with a non-empty path component under the SHA segment, making the URI look like a directory. The diff editor threw "Directory not found". The `buildGitBlobUri` path structure (`/<urlencode(sha)>/<hex(path)>/<basename>`) has a decorative basename at the end; the fix was to not produce a `git-blob:` URI for added files at all (omit `originalUri`). **Prevented by:** gotcha on `gitDiffContent.ts:buildGitBlobUri` in [agent-host-git-driven-diffs](docs/agent-host-git-driven-diffs.md#debt--gotchas), and a test for the added-file case.
- **Deleted-file diff tried to open the nonexistent file** — `diffsToChanges` fell back to the pre-deletion file path for `modifiedUri` when `d.after` was absent. The diff editor threw "Unable to resolve nonexistent file". **Prevented by:** gotcha on `agentHostDiffs.ts:diffsToChanges` in [agent-host-git-driven-diffs](docs/agent-host-git-driven-diffs.md#debt--gotchas), and a test for the deleted-file case in `agentHostDiffs.test.ts` (which doesn't exist yet — see debt).
- **Both bugs escaped because `agentHostDiffs.ts` has no tests** — the conversion function was written and tested only by running the full product. **Prevented by:** debt entry in [testing.md](docs/testing.md#debt--gotchas).
- **`IAgentHostGitService` passed through options bag instead of DI** — caught in code review. The correct pattern is to register the service in `AgentService`'s local `ServiceCollection` and inject via decorator. **Prevented by:** the existing gotcha about constructor deps being required in `agent-host-sessions-providers.md`.
- **Raw `fs/promises` / `os` usage** — the initial implementation used raw node modules. Refactoring to `IFileService` / `INativeEnvironmentService` required restructuring `agentHostMain.ts` and `agentHostServerMain.ts` to build the `InstantiationService` before creating `AgentHostGitService`. Easy to miss that there's a second entry point (`agentHostServerMain.ts`). **Prevented by:** always search for both `agentHostMain` and `agentHostServerMain` when changing constructor signatures for services instantiated at startup.
- **Missing `COMMAND_HOOK_LOCK=1` for GVFS** — needed to mirror the extension-host CLI's `buildTempIndexEnv`. Discovered only by reading the CLI source during the code-sharing investigation. **Prevented by:** gotcha in [agent-host-git-driven-diffs](docs/agent-host-git-driven-diffs.md#debt--gotchas).

## What we learned

- `IChatSessionFileChange` vs `IChatSessionFileChange2` is a load-bearing distinction. The two-type union (`ISessionFileChange`) exists precisely because the legacy `IChatSessionFileChange` (required `modifiedUri`) can't express deletions. Any new diff source should use `IChatSessionFileChange2`.
- The `changes` observable in `BaseAgentHostSession` was typed as `IChatSessionFileChange[]`. Widening it to `(IChatSessionFileChange | IChatSessionFileChange2)[]` (matching `ISessionFileChange`) is the correct fix; narrowing only one call site with a cast would not help the type of `changes.get()` returned elsewhere.
- The `changesViewRenderer.ts` / `changesView.ts` deletion-detection contract (`modifiedUri === undefined`) is not obviously documented anywhere in the codebase. It is now documented in the new [agent-host-git-driven-diffs](docs/agent-host-git-driven-diffs.md) doc.
- Code sharing with the extension-host CLI diff logic is not feasible at the type level without adapters. The right approach is to understand the extension's algorithm (git commands, temp-index, GVFS env) and re-implement it cleanly in AHP-native types.
- `AgentSideEffects._computeGitDrivenDiffs` silently no-ops when `META_DIFF_BASE_BRANCH` is absent. For non-worktree or pre-key sessions this means no branch-changes diffs with no error. A future improvement is to fall back to `getDefaultBranch()`.

## Doc updates

- **New**: `docs/agent-host-git-driven-diffs.md` — covers `AgentHostGitService.computeSessionFileDiffs`, `_runWithTempIndex`, `git-blob:` URI scheme, `diffsToChanges` / `IChatSessionFileChange2` contract, and testing. Includes gotchas for the two fixed bugs and for GVFS.
- **Updated**: `docs/testing.md` — added `debt` entry for `agentHostDiffs.ts` having no unit tests.
- **Updated**: `docs/agent-host-sessions-providers.md` — added `debt` entry for the `META_DIFF_BASE_BRANCH` silent-fallback; added changelog entry.
- **Updated**: `docs/copilot-extension-host-cli.md` — updated parity gaps paragraph to note that git-driven diffs now exist; clarified distinction from auto-commit/checkpoint.
- **Updated**: `index.md` — added the new doc to the Docs list; added cross-cutting debt entry for `agentHostDiffs.ts` missing tests.
