# Agent Host Git-Driven Session Diffs

_Covers: src/vs/platform/agentHost/node/agentHostGitService.ts, src/vs/platform/agentHost/node/agentHostGitStateService.ts, src/vs/platform/agentHost/node/agentService.ts, src/vs/platform/agentHost/node/gitDiffContent.ts, src/vs/platform/agentHost/common/fileEditDiff.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostDiffs.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostResponseFileChanges.ts, src/vs/platform/agentHost/test/node/agentHostGitService.integrationTest.ts, src/vs/platform/agentHost/test/node/agentHostGitStateService.test.ts, src/vs/platform/agentHost/test/node/agentService.test.ts, src/vs/platform/agentHost/test/node/agentSideEffects.test.ts, src/vs/workbench/contrib/chat/test/browser/agentHost/agentHostResponseFileChanges.test.ts_

The "Branch changes" mode in the agent window's Changes view shows which files the agent modified since the session started. This is driven by `git diff` rather than by tracking individual editor saves, so it catches changes made via terminal commands, external tools, or any other mechanism.

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

UI surfaces: `agentHostDiffs.ts` (diff → changes conversion, below) and `agentHostSessionChangesets.ts` (changeset catalogue rendering in the agent window).

## Git-state lifecycle for provisional worktrees

Git state (`SessionState._meta.git`) has a different lifecycle from the worktree path itself. An eagerly created provisional session starts in `SessionLifecycle.Creating` with the user's selected checkout as its temporary `workingDirectory`; the isolated worktree does not exist until the first prompt materializes the provider session. `AgentHostGitStateService.refreshSessionGitState` therefore returns without probing for every `Creating` session, regardless of whether the caller is subscribe, turn completion, or a file monitor. This invariant belongs in the Git-state service rather than at individual call sites.

At materialization, `AgentService._onDidMaterializeSession` first calls `markSessionPersisted`, which publishes `root/sessionAdded` with the final project and worktree working directory, then transitions the session to `Ready` and starts `refreshSessionGitState` against the worktree. The resulting `SessionMetaChanged` action reaches subscribed clients immediately; `SessionSummaryNotifier` also emits the same `_meta.git` through a debounced `root/sessionSummaryChanged` for list-only clients. Runtime validation for PR [#324280](https://github.com/microsoft/vscode/pull/324280) measured the corrected branch summary about 185ms after `sessionAdded`, before turn completion.

`AgentService.listSessions` also overlays live `modifiedAt`, `project`, and `workingDirectory` from `AgentHostStateManager` onto each provider result. Provider list calls may snapshot metadata before materialization and finish afterward; without the live overlay, that stale result could overwrite the worktree path even though `sessionAdded` already published the correct value.

## How it works end-to-end

1. **Anchor point** — When `CopilotAgent` creates or resumes a session it writes `META_DIFF_BASE_BRANCH` (`'agentHost.diffBaseBranch'`) into the per-session database. The value is the name of the branch from which the worktree was forked (e.g. `main`). `AgentSideEffects._computeGitDrivenDiffs` reads it back at turn-end.

2. **Diff computation** (`AgentHostGitService.computeSessionFileDiffs`) — Runs `git diff --raw --numstat --diff-filter=ADMR -z <mergeBase> --` in the session's working directory. `mergeBase` is resolved against the recorded base branch, preferring its `origin/<default>` tracking ref when that is the stable branch identity; branch-base maintenance also repairs stored worktree metadata after the base moves so branch diffs keep comparing against the intended lineage. It falls back to `HEAD` alone when no base branch is stored or resolvable. When the working tree has untracked files (common after a tool writes a new file before it is committed), the diff is run against a **temp index** (see below). All git invocations run from the repository root resolved by `getRepositoryRoot`, which now **caches** the `git rev-parse --show-toplevel` result per working directory (`_repositoryRoots`, an `LRUCache` capped at 100 entries) behind a `SequencerByKey` so concurrent callers for the same directory share one resolution instead of each shelling out.

   Turn-scoped and turn-to-turn diffs (`changeKind: turn` / `compare-turns`, see the changeset section above) go through the sibling `computeFileDiffsBetweenRefs(fromRef, toRef)` instead, diffing two checkpoint refs directly. That path no longer pre-resolves each ref with `git rev-parse --verify` before diffing — it runs `git diff <fromRef> <toRef>` directly and catches/logs a failure (e.g. a missing ref) rather than bailing out early on a separate resolve step.

3. **Temp index dance** (`_runWithTempIndex` / `_stageChangedPaths`) — Creates a throwaway `GIT_INDEX_FILE` in a temp dir, seeds it with `git read-tree HEAD` (or the empty-tree object for HEAD-less repos), and runs `git diff --cached` against it. Staging is scoped to only the paths `git status` reported as changed, written to a NUL-separated pathspec file and applied via `git add -A --pathspec-from-file=<file> --pathspec-file-nul` (with `GIT_LITERAL_PATHSPECS=1`) — not a blanket `git add -A -- :/`, which used to walk nested repos/worktrees and large checkouts and made temp-index diffing slow and timeout-prone. Sets `COMMAND_HOOK_LOCK=1` to prevent GVFS repos from acquiring the per-worktree hook lock during the temp-index operations, mirroring the extension-host CLI's `buildTempIndexEnv`.

4. **`git-blob:` URI scheme** (`gitDiffContent.ts`) — Each `ISessionFileDiff.before.content.uri` is a `git-blob:` URI built by `buildGitBlobUri(sessionUri, ref, repoRelativePath, absolutePath)`: the URI `path` is the absolute working-tree path (so resource labels and the diff editor's "after" side line up with a real file), and `sessionUri` / `ref` / `repoRelativePath` ride as a JSON blob in the URI `query`. `ref` used to be named `sha` and was regex-validated as a bare 40-char-or-fewer hex object name; it is now any git ref string (including a checkpoint ref like `refs/agents/<sid>/checkpoints/turn/<N>`, needed for the per-turn/compare-turns changeset modes) and is **no longer validated** — see the gotcha below. There is no dedicated `GitBlobFilesystemProvider`: the shared `AgentHostFileSystemProvider` (`src/vs/platform/agentHost/common/agentHostFileSystemProvider.ts`) special-cases the `git-blob:` (and `session-db:`) scheme and forwards the read as a generic AHP `resourceRead` request instead of resolving it as a real file path. Server-side, `AgentService.resourceRead` detects the scheme via `parseGitBlobUri` and calls `_fetchGitBlobContent`, which looks up the session's working directory and calls `IAgentHostGitService.showBlob(workingDirectory, ref, repoRelativePath)` → `git show <ref>:<path>`. The diff editor reads the "before" content from this URI.

5. **`diffsToChanges` conversion** (`agentHostDiffs.ts`) — Converts `ISessionFileDiff[]` (protocol-layer type from `sessionState.ts`) to `IChatSessionFileChange2[]` (the sessions-layer type), one file at a time via `diffToChange`. `diffToChange` delegates the create/delete/rename/edit classification and "primary resource" rule (after-URI for create/edit/rename, before-URI for delete) to the shared `normalizeFileEdit` helper (`src/vs/platform/agentHost/common/fileEditDiff.ts`), which also backs the changeset-channel's `changesetFileToChange` / `changesetFilesToChanges` / `changesetFilesEqual` siblings so all diff-shaped consumers agree on the same classification. `diffsToChanges` always returns `IChatSessionFileChange2`, which carries both a mandatory `uri` (the canonical identity for the tree row) and an optional `modifiedUri`. The `modifiedUri` distinction is load-bearing: the renderer (`changesViewRenderer.ts`) detects deletions by `change.modifiedUri === undefined`.

6. **Observable deduplication** — `diffsEqual` guards every `changes.set(...)` call in `BaseAgentHostSession`, comparing by `uri`, `insertions`, `deletions`, and `originalUri`. No-op updates are skipped so the observable doesn't trigger a render cycle unnecessarily.

## Per-turn file-changes summary in chat responses

The "Changed N files" summary line rendered under a completed agent-host chat response (`chatChangesSummaryPart.ts`) is driven by the same per-turn changeset the agent window's Changes view uses, not by the chat editing session. `IChatResponseFileChangesService` (`src/vs/workbench/contrib/chat/browser/chatResponseFileChangesService.ts`) is a per-session-type provider registry; the summary content part consults it before falling back to the editing session, and self-hides when the resolved diffs are empty. `AgentHostSessionHandler` registers an `AgentHostResponseFileChangesProvider` (`agentHostResponseFileChanges.ts`) per session type, which subscribes to the session's per-turn changeset (keyed by the response's turn id) and maps its files into edit-session diffs via the same `normalizeFileEdit`-backed helpers described above.

Per-turn changesets are computed lazily when a client subscribes, so a restored response initially has no file entries and becomes visible after the changeset resolves. `AgentHostResponseFileChangesProvider` derives the expanded per-turn changeset URI from session state; that URI-valued derived must compare with resource equality (`derivedOpts({ equalsFn: isEqual })`). Session metadata can update while the resource remains semantically unchanged, and object-identity comparison would otherwise replace the inner changeset subscription, briefly exposing an empty state and making the summary disappear and reappear.

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

`buildGitBlobUri(sessionUri, ref, repoRelativePath, absolutePath)` (`gitDiffContent.ts`) builds:

```
git-blob:<absolutePath>?{"sessionUri":"...","sha":"<ref>","repoRelativePath":"..."}
```

- **path**: the absolute working-tree path, used only as a human-readable display path (editor tab titles, resource labels) — it is not used to resolve content.
- **query**: a JSON object (`IGitBlobUriQuery`) carrying the actual identity used to fetch the blob: `sessionUri` (which working directory to run `git show` from), `sha` (the ref to read at — despite the field name, any git ref string, not only a 40-char commit SHA), and `repoRelativePath` (the path passed to `git show <ref>:<repoRelativePath>`).

`parseGitBlobUri` is the inverse, returning `undefined` for anything that isn't a `git-blob:` URI with a well-formed JSON query. Resolution is server-side: `AgentService.resourceRead` recognizes the scheme and calls `_fetchGitBlobContent`, which throws a `ProtocolError` (`AhpErrorCodes.NotFound`) if the session has no working directory or the blob can't be read.

## Testing

- `src/vs/platform/agentHost/test/node/agentHostGitService.integrationTest.ts` — real git integration tests using a temporary git repo on disk. Covers `computeSessionFileDiffs` for modifications, additions, deletions, renames; the temp-index path for untracked files; and `showBlob` for known and unknown SHAs.
- `src/vs/platform/agentHost/test/node/agentSideEffects.test.ts` — unit tests for the `AgentSideEffects` git diff path (DB meta read, `computeSessionFileDiffs` stub, `changes.set` dispatch).
- `src/vs/workbench/contrib/chat/test/browser/agentHost/agentHostResponseFileChanges.test.ts` — provider tests for per-turn mapping, memoization, unsupported sessions, and preserving the changeset subscription across equivalent session-state updates.
- `agentHostDiffs.ts` has **no direct unit tests** (see gotcha below).

## Debt & gotchas

- **gotcha** (2026-04-26, agentHostDiffs.ts:diffsToChanges) — always return `IChatSessionFileChange2`, **not** `IChatSessionFileChange`. The renderer (`changesViewRenderer.ts:toIChangesFileItem`) detects deletions via `change.modifiedUri === undefined` and looks up the list-row key via `isIChatSessionFileChange2(change) ? change.uri : change.modifiedUri`. If you return the legacy `IChatSessionFileChange` shape for a deletion, `modifiedUri` will be set to the pre-deletion filesystem path and the diff editor will throw "Unable to resolve nonexistent file". PR [#312632](https://github.com/microsoft/vscode/pull/312632) fixed this by switching the return type to `IChatSessionFileChange2` throughout `agentHostDiffs.ts` and updating `BaseAgentHostSession.changes` to `(IChatSessionFileChange | IChatSessionFileChange2)[]` to match `ISessionFileChange`.
- **gotcha** (2026-07-04, agentHostResponseFileChanges.ts:_createDiffsObservable) — compare derived changeset `URI` values with `isEqual`, not object identity. Session-state updates can reconstruct the same expanded turn URI; treating it as new tears down and reacquires the changeset subscription, temporarily publishing no files and flickering the response summary.
- **gotcha** (2026-06-08, gitDiffContent.ts:buildGitBlobUri, PR [#317450](https://github.com/microsoft/vscode/pull/317450)) — `git-blob:` URIs are **no longer** the hex-path-segment scheme this doc previously described. The path is now the plain absolute working-tree path (so editor tabs/labels show a real filename) and `sessionUri` / `sha` (really: ref) / `repoRelativePath` ride as a JSON blob in the URI query, parsed by `parseGitBlobUri`. This resolved the old segment-order footgun (there are no positional segments to get wrong) but means anything that inspects a `git-blob:` URI's `path` directly (rather than going through `parseGitBlobUri`) is reading a display path, not the identity. This drift between doc and code went unnoticed through the 2026-06-25 reconciliation; see the current "`git-blob:` URI structure" section above for the real shape.
- **gotcha** (2026-04-26, agentHostGitService.ts:_runWithTempIndex) — the temp index must set `COMMAND_HOOK_LOCK=1` for GVFS repos, mirroring `buildTempIndexEnv` in the extension-host CLI. Without this, `git add -A` will attempt to acquire the per-worktree hook lock while the main process already holds it, causing the operation to hang.
- **gotcha** (2026-07-03, agentHostGitStateService.ts:refreshSessionGitState) — do not compute Git state while `SessionState.lifecycle === Creating`. The session's current `workingDirectory` is the selected checkout and may later relocate to an isolated worktree, so probing early publishes the base branch as session truth. Keep the lifecycle guard centralized in `AgentHostGitStateService`; guarding only subscribe leaves turn-complete and file-monitor callers able to reintroduce stale metadata.
- **debt** (2026-07-02, agentHostGitService.ts:showBlob, PR [#323932](https://github.com/microsoft/vscode/pull/323932)) — `showBlob`'s second parameter was renamed `sha` → `ref` and its `/^[0-9a-f]{4,64}$/` validation was **removed** so checkpoint refs (e.g. `refs/agents/<sid>/checkpoints/turn/<N>`) can flow through, not just merge-base commit SHAs. Today `ref` only ever comes from internally-computed merge-base SHAs or internally-constructed checkpoint refs, but `git show` receives `${ref}:${repoRelativePath}` as a single argv token via `cp.execFile`, so a future caller that threads a session/user-influenced string into this parameter could have it interpreted as a git option if it starts with `-`. Worth adding shape validation back (SHA hex OR the internal checkpoint-ref pattern) if a less-trusted caller is ever added, rather than leaving `ref` fully unvalidated.
- **debt** (2026-04-26, agentHostDiffs.ts) — `agentHostDiffs.ts` has **no unit tests** of its own. The create/delete/rename/edit classification and "primary resource" logic that used to live duplicated here now lives in the shared, unit-tested `normalizeFileEdit` (`src/vs/platform/agentHost/common/fileEditDiff.ts`, covered by `fileEditDiff.test.ts`), so the original added-file/deleted-file classification bugs this entry was written for are now covered indirectly. The thin `diffToChange`/`diffsToChanges` glue in `agentHostDiffs.ts` — URI rebasing via `mapUri`, and the `IChatSessionFileChange2` field wiring itself — still has no dedicated test file. See [testing.md](./testing.md) for the test runner.
- **debt** (2026-04-26, agentSideEffects.ts:_computeGitDrivenDiffs) — the git-driven diff path in `AgentSideEffects` falls back silently to no-op when `META_DIFF_BASE_BRANCH` is absent from the DB. This means sessions created before the key was introduced (or sessions for non-worktree repos) simply show no branch-changes diffs without any indication why. A future improvement would be to fall back to a `getDefaultBranch()` call when the key is absent, rather than skipping the diff entirely.

## Changelog

- **2026-07-04** — 577ed33078 — documented lazy per-turn summary resolution and the resource-equality requirement that prevents equivalent session updates from replacing the changeset subscription. PR [#324282](https://github.com/microsoft/vscode/pull/324282).
- **2026-07-03** — 46620a421f — documented provisional worktree Git-state ordering: suppress all `Creating`-lifecycle probes, refresh against the final worktree after materialization, publish through `SessionMetaChanged` / `SessionSummaryChanged`, and overlay live workspace metadata over stale provider list snapshots. PR [#324280](https://github.com/microsoft/vscode/pull/324280).
- **2026-07-02** — f9f2fd558a — reconciliation: fixed the `git-blob:` URI structure section, which was stale since the query-based encoding landed in PR [#317450](https://github.com/microsoft/vscode/pull/317450) (2026-06-08, missed by the 2026-06-25 reconciliation) — corrected the "GitBlobFilesystemProvider" description to the actual `AgentHostFileSystemProvider` scheme-forwarding + `AgentService.resourceRead` → `_fetchGitBlobContent` → `showBlob` server-side resolution path. Documented `showBlob`'s `sha`→`ref` rename and removed regex validation (PR [#323932](https://github.com/microsoft/vscode/pull/323932), checkpoint-ref support), `computeFileDiffsBetweenRefs` no longer pre-resolving refs (PR #323422), repository-root LRU caching (PR #323097), and the pathspec-file-scoped temp-index staging (previously described as a blanket `git add -A -- :/`). Added the **Per-turn file-changes summary in chat responses** section (`IChatResponseFileChangesService` / `AgentHostResponseFileChangesProvider`) and noted the shared `normalizeFileEdit` helper `diffToChange` now delegates to. Added `fileEditDiff.ts` to Covers.

- **2026-06-25** — 09c18fe5c5 — reconciliation: added the **Changeset channel & service decomposition** section. The monolithic `agentHostGitService` was split into `IAgentHostGitService` / `IAgentHostGitStateService` / `IAgentHostChangesetService` / `IAgentHostChangesetOperationService` / `IAgentHostChangesetSubscriptionService` + `AgentHostChangesetCoordinator` / `StateCache` / `ChangesetFileMonitorCoordinator` / `IAgentHostCheckpointService`. Documented the `channels-changeset` wire shape (`Changeset.changeKind` session/branch/uncommitted/turn/compare-turns, `ChangesetState`, `ChangesetOperation`, the seven changeset actions, `invokeChangesetOperation`), per-turn checkpoints under `refs/agents/<sid>/checkpoints/turn/<N>`, the PR/commit/sync/discard operation handlers, and `agentHostSessionChangesets.ts`. The lower-level `git-blob:` / temp-index machinery is unchanged.

- **2026-05-15** — 12443ea83d — reconciliation: documented worktree/base-branch diff repair from `e1615a45e22` and `514255bd1ea`, and updated the Sessions provider path after `a3d955d72ad`.

- **2026-05-01** — b2e6267136 — reconciliation: no body changes. `8ae0d8eab63d` introduced the git-driven diffs already documented here; later worktree cleanup, plugin configuration, and activity-event commits in this area did not change the diff architecture or `agentHostDiffs.ts` shape rules.
- **2026-04-26** — `b86149ad81` — initial entry. PR [#312632](https://github.com/microsoft/vscode/pull/312632).
