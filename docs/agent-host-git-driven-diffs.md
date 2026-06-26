# Agent Host Git-Driven Session Diffs

_Covers: src/vs/platform/agentHost/node/agentHostGitService.ts, src/vs/platform/agentHost/node/gitDiffContent.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostDiffs.ts, src/vs/platform/agentHost/test/node/agentHostGitService.integrationTest.ts, src/vs/platform/agentHost/test/node/agentSideEffects.test.ts_

The "Branch changes" mode in the agents-app Changes view shows which files the agent modified since the session started. This is driven by `git diff` rather than by tracking individual editor saves, so it catches changes made via terminal commands, external tools, or any other mechanism.

> **Newer model: the changeset channel.** The raw `computeSessionFileDiffs` path below is now the lowest layer underneath a **protocolized changeset channel** (`agentHost: changeset operations channel` and the surrounding service split). Diffs are no longer just a renderer-computed list — they are a server-declared catalog of `Changeset`s, each with subscribable `ChangesetState` and invokable `ChangesetOperation`s. See [Changeset channel & service decomposition](#changeset-channel--service-decomposition) for the current shape; the `AgentHostGitService` / `git-blob:` machinery documented in detail below is what those services sit on top of.

## Changeset channel & service decomposition

The single `agentHostGitService` has been decomposed into a set of focused services (common interfaces + `node/` implementations under `src/vs/platform/agentHost/`):

| Service | Responsibility |
|---|---|
| `IAgentHostGitService` | raw git plumbing (diff, `git show`, temp-index, blob resolution) — the layer this doc's lower half describes |
| `IAgentHostGitStateService` | computes `ISessionGitState` / `ISessionGitHubState` and publishes them onto session `_meta` (see [agent-host-protocol](./agent-host-protocol.md)) |
| `IAgentHostChangesetService` | owns the `Changeset` catalogue + `ChangesetState` for a session |
| `IAgentHostChangesetOperationService` | registers and dispatches `ChangesetOperation`s (stage / revert / create-pr / commit / sync / discard) |
| `IAgentHostChangesetSubscriptionService` | wires changeset state into the AHP subscription/notification flow |
| `AgentHostChangesetCoordinator` / `AgentHostChangesetStateCache` / `ChangesetFileMonitorCoordinator` | orchestration, caching, and file-system watching that keeps changeset state live |
| `IAgentHostCheckpointService` | per-turn git checkpoints (see below) |

**Changeset channel wire shape** (`channels-changeset`, addressed `<sessionUri>/changeset/<id>`):

- `Changeset { label; uriTemplate; changeKind }` where `changeKind` ∈ `session | branch | uncommitted | turn | compare-turns` — the different "what am I diffing against" modes (whole-session, base-branch, working-tree, a single turn, or two turns).
- `ChangesetState { status; files: ChangesetFile[]; operations?: ChangesetOperation[] }`.
- `ChangesetOperation { id; label; scopes; confirmation?; group?; status }` — a server-declared, client-invokable action (stage, revert, create-pr, …). Clients invoke them via the `invokeChangesetOperation` command rather than hard-coding git buttons in the UI.
- Seven state actions: `ChangesetStatusChanged`, `ChangesetFileSet`, `ChangesetFileRemoved`, `ChangesetContentChanged`, `ChangesetOperationsChanged`, `ChangesetOperationStatusChanged`, `ChangesetCleared`.

**Operations** are handled by dedicated handlers (PR / commit / sync / discard). The PR handler in particular (`AgentHostPullRequestOperationProvider` / `AgentHostPullRequestOperationHandler`, `IAgentHostOctoKitService`) is shared with the GitHub/PR surface documented in [agent-host-sessions-providers](./agent-host-sessions-providers.md).

**Checkpoints** (`IAgentHostCheckpointService`). The server captures a git checkpoint per turn under `refs/agents/<sid>/checkpoints/turn/<N>` (`captureBaseline`, `captureTurnCheckpoint`, `getTurnCheckpointPair`). These capture the **full worktree delta including terminal-driven edits**, which is what makes per-turn (`changeKind: turn`) and turn-to-turn (`compare-turns`) diffs possible — they compare checkpoint refs rather than recomputing from the base branch each time.

UI surfaces: `agentHostDiffs.ts` (diff → changes conversion, below) and `agentHostSessionChangesets.ts` (changeset catalogue rendering in the agents app).

## How it works end-to-end

1. **Anchor point** — When `CopilotAgent` creates or resumes a session it writes `META_DIFF_BASE_BRANCH` (`'agentHost.diffBaseBranch'`) into the per-session database. The value is the name of the branch from which the worktree was forked (e.g. `main`). `AgentSideEffects._computeGitDrivenDiffs` reads it back at turn-end.

2. **Diff computation** (`AgentHostGitService.computeSessionFileDiffs`) — Runs `git diff --raw --numstat --diff-filter=ADMR -z <mergeBase> --` in the session's working directory. `mergeBase` is resolved against the recorded base branch, preferring its `origin/<default>` tracking ref when that is the stable branch identity; branch-base maintenance also repairs stored worktree metadata after the base moves so branch diffs keep comparing against the intended lineage. It falls back to `HEAD` alone when no base branch is stored or resolvable. When the working tree has untracked files (common after a tool writes a new file before it is committed), the diff is run against a **temp index** (see below).

3. **Temp index dance** (`_runWithTempIndex`) — Creates a throwaway `GIT_INDEX_FILE` in a temp dir, seeds it with `git read-tree HEAD` (or the empty-tree SHA for HEAD-less repos), stages everything with `git add -A -- :/`, and runs `git diff --cached`. Sets `COMMAND_HOOK_LOCK=1` to prevent GVFS repos from acquiring the per-worktree hook lock during the temp-index operations, mirroring the extension-host CLI's `buildTempIndexEnv`.

4. **`git-blob:` URI scheme** (`gitDiffContent.ts`) — Each `ISessionFileDiff.before.content.uri` is a `git-blob:` URI encoding (hex-encoded `sessionUri`, URL-encoded SHA, hex-encoded repo-relative path) constructed by `buildGitBlobUri`. The agents-app registers a filesystem provider (`GitBlobFilesystemProvider` in `agentHostGitService.ts`) that resolves these URIs by calling `showBlob(workingDirectory, sha, repoRelativePath)` → `git show <sha>:<path>`. The diff editor reads the "before" content from this URI.

5. **`diffsToChanges` conversion** (`agentHostDiffs.ts`) — Converts `ISessionFileDiff[]` (protocol-layer type from `sessionState.ts`) to `IChatSessionFileChange2[]` (the sessions-layer type). Always returns `IChatSessionFileChange2`, which carries both a mandatory `uri` (the canonical identity for the tree row) and an optional `modifiedUri`. The `modifiedUri` distinction is load-bearing: the renderer (`changesViewRenderer.ts`) detects deletions by `change.modifiedUri === undefined`.

6. **Observable deduplication** — `diffsEqual` guards every `changes.set(...)` call in `BaseAgentHostSession`, comparing by `uri`, `insertions`, `deletions`, and `originalUri`. No-op updates are skipped so the observable doesn't trigger a render cycle unnecessarily.

## `ISessionFileDiff` shape for each status

| Status   | `before`     | `after`      | `before.content.uri`          | `after.content.uri`  |
|----------|-------------|-------------|-------------------------------|----------------------|
| added    | absent      | present     | absent                        | `file:` working-tree |
| modified | present     | present     | `git-blob:` merge-base SHA    | `file:` working-tree |
| deleted  | present     | absent      | `git-blob:` merge-base SHA    | absent               |
| renamed  | present (old path) | present (new path) | `git-blob:` old SHA | `file:` new path |

## `diffsToChanges`: what to return for each status

`diffsToChanges` must return `IChatSessionFileChange2` for all cases. The key rule:

- **Deleted files**: `modifiedUri` must be `undefined`. The "after" side does not exist on disk, so `d.after` is absent. Setting `modifiedUri` to the pre-deletion path causes the diff editor to try to read a nonexistent file. The `uri` field (always present in `IChatSessionFileChange2`) is set to the deleted file's path so the tree row has an identity.
- **Added files**: `originalUri` must be `undefined`. The "before" blob does not exist; `d.before` is absent.
- **Modified/renamed**: both `uri` and `modifiedUri` match `d.after.uri`; `originalUri` points to the `git-blob:` URI.

## `git-blob:` URI structure

```
git-blob://<hex(sessionUri)>/<urlencode(sha)>/<hex(repoRelativePath)>/<basename>
```

- **authority**: hex-encoded session URI (used by the filesystem provider to look up the working directory for `git show`).
- **path segments**: URL-encoded SHA (40-char hex), hex-encoded repo-relative path, and finally the raw basename. The basename is decorative (for editor tab titles) and is ignored during parsing; the hex-encoded path is the authoritative source.

`parseGitBlobUri` is the inverse. When the filesystem provider can't resolve a `git-blob:` URI (e.g. the session has ended), it throws `FileSystemProviderError.FileNotFound`.

## Testing

- `src/vs/platform/agentHost/test/node/agentHostGitService.integrationTest.ts` — real git integration tests using a temporary git repo on disk. Covers `computeSessionFileDiffs` for modifications, additions, deletions, renames; the temp-index path for untracked files; and `showBlob` for known and unknown SHAs.
- `src/vs/platform/agentHost/test/node/agentSideEffects.test.ts` — unit tests for the `AgentSideEffects` git diff path (DB meta read, `computeSessionFileDiffs` stub, `changes.set` dispatch).
- `agentHostDiffs.ts` has **no direct unit tests** (see gotcha below).

## Debt & gotchas

- **gotcha** (2026-04-26, agentHostDiffs.ts:diffsToChanges) — always return `IChatSessionFileChange2`, **not** `IChatSessionFileChange`. The renderer (`changesViewRenderer.ts:toIChangesFileItem`) detects deletions via `change.modifiedUri === undefined` and looks up the list-row key via `isIChatSessionFileChange2(change) ? change.uri : change.modifiedUri`. If you return the legacy `IChatSessionFileChange` shape for a deletion, `modifiedUri` will be set to the pre-deletion filesystem path and the diff editor will throw "Unable to resolve nonexistent file". PR [#312632](https://github.com/microsoft/vscode/pull/312632) fixed this by switching the return type to `IChatSessionFileChange2` throughout `agentHostDiffs.ts` and updating `BaseAgentHostSession.changes` to `(IChatSessionFileChange | IChatSessionFileChange2)[]` to match `ISessionFileChange`.
- **gotcha** (2026-04-26, gitDiffContent.ts:buildGitBlobUri) — the `git-blob:` URI path has three segments: `/<urlencode(sha)>/<hex(repoRelativePath)>/<basename>`. The **basename is decorative** — it exists so the diff editor tab shows a human-readable filename. Parsing always uses the hex-encoded second segment for the path, not the third. If you are tempted to construct a `git-blob:` URI manually, use `buildGitBlobUri` — hand-rolling it with the wrong segment order is the root cause of the original "new file diff" bug (the path ended up as a directory component of the SHA segment).
- **gotcha** (2026-04-26, agentHostGitService.ts:_runWithTempIndex) — the temp index must set `COMMAND_HOOK_LOCK=1` for GVFS repos, mirroring `buildTempIndexEnv` in the extension-host CLI. Without this, `git add -A` will attempt to acquire the per-worktree hook lock while the main process already holds it, causing the operation to hang.
- **debt** (2026-04-26, agentHostDiffs.ts) — `agentHostDiffs.ts` has **no unit tests**. Both the added-file bug and the deleted-file bug were caught manually in the running product rather than by a test. A `agentHostDiffs.test.ts` covering all four `ISessionFileDiff` status values (added, modified, deleted, renamed) with and without `mapUri` would have caught both regressions. See [testing.md](./testing.md) for the test runner.
- **debt** (2026-04-26, agentSideEffects.ts:_computeGitDrivenDiffs) — the git-driven diff path in `AgentSideEffects` falls back silently to no-op when `META_DIFF_BASE_BRANCH` is absent from the DB. This means sessions created before the key was introduced (or sessions for non-worktree repos) simply show no branch-changes diffs without any indication why. A future improvement would be to fall back to a `getDefaultBranch()` call when the key is absent, rather than skipping the diff entirely.

## Changelog

- **2026-06-25** — 09c18fe5c5 — reconciliation: added the **Changeset channel & service decomposition** section. The monolithic `agentHostGitService` was split into `IAgentHostGitService` / `IAgentHostGitStateService` / `IAgentHostChangesetService` / `IAgentHostChangesetOperationService` / `IAgentHostChangesetSubscriptionService` + `AgentHostChangesetCoordinator` / `StateCache` / `ChangesetFileMonitorCoordinator` / `IAgentHostCheckpointService`. Documented the `channels-changeset` wire shape (`Changeset.changeKind` session/branch/uncommitted/turn/compare-turns, `ChangesetState`, `ChangesetOperation`, the seven changeset actions, `invokeChangesetOperation`), per-turn checkpoints under `refs/agents/<sid>/checkpoints/turn/<N>`, the PR/commit/sync/discard operation handlers, and `agentHostSessionChangesets.ts`. The lower-level `git-blob:` / temp-index machinery is unchanged.

- **2026-05-15** — 12443ea83d — reconciliation: documented worktree/base-branch diff repair from `e1615a45e22` and `514255bd1ea`, and updated the Sessions provider path after `a3d955d72ad`.

- **2026-05-01** — b2e6267136 — reconciliation: no body changes. `8ae0d8eab63d` introduced the git-driven diffs already documented here; later worktree cleanup, plugin configuration, and activity-event commits in this area did not change the diff architecture or `agentHostDiffs.ts` shape rules.
- **2026-04-26** — `b86149ad81` — initial entry. PR [#312632](https://github.com/microsoft/vscode/pull/312632).
