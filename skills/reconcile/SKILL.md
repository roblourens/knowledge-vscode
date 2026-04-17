---
name: reconcile
description: "Detect drift between the VS Code agent host knowledge docs and the current VS Code codebase, and update the docs in place to match. Use when the user says 'reconcile knowledge', 'check for drift', 'update knowledge docs', 'audit the knowledge base', or runs this periodically (e.g., weekly, after teammates' PRs land). Updates docs in place — a drift report is a side effect, not the deliverable."
---

# Skill: reconcile

Detect and **fix** drift between the knowledge docs and the current state of the VS Code codebase. The deliverable is updated docs, not a report.

The trick: don't re-read every doc against every code reference. Use the VS Code Git history since each doc's baseline SHA — if nothing relevant has changed in the area a doc covers, the doc is presumed current and is skipped.

## Precondition

Knowledge repo must be set up. If `$VSCODE_REPO/.knowledge` doesn't exist as a symlink, or doesn't resolve, run `init` first.

Re-derive what you need each time:

- `KNOWLEDGE_CHECKOUT = realpath "$VSCODE_REPO/.knowledge"`
- `VSCODE_REPO` from `git rev-parse` against the workspace root.

Reconciliation is normally run from the main VS Code checkout, against `origin/main`. If running from a worktree on a feature branch, ask the user whether to reconcile against `origin/main` (recommended) or `HEAD`.

Make sure the VS Code repo is up to date with the remote: `git -C "$VSCODE_REPO" fetch origin --quiet`.

## Workflow

### 1. Walk the docs

For each `*.md` under `$KNOWLEDGE_CHECKOUT/docs/`:

- Read the `Covers:` line to get the list of VS Code paths the doc claims responsibility for.
- Read the most recent changelog entry to get the doc's baseline SHA and date.
- Scan the doc body for additional code references: file paths under `src/`, class names, function names mentioned in code-style backticks. Treat these as supplementary references on top of `Covers:`.

### 2. Compute the change set per doc

For each doc, determine what has changed in the VS Code repo since its baseline:

1. Try `git -C "$VSCODE_REPO" log <baseline-sha>..origin/main --name-only -- <covers paths>` to list commits and changed files.
2. If the baseline SHA isn't reachable from `origin/main` (rebase, squash, abandoned branch), fall back to `git -C "$VSCODE_REPO" log --since=<baseline-date> --name-only origin/main -- <covers paths>`.

If the result is empty, the doc is **presumed current**. Skip it. Do not re-read it against the code.

### 3. Cheap mechanical pass (always run)

Independent of baselines, do a fast existence check across all docs:

- For each path reference, verify it still exists in `origin/main` (`git -C "$VSCODE_REPO" cat-file -e origin/main:<path>`).
- For each named class or function, do a quick grep in the relevant file to check it still exists.

Anything that's been deleted, renamed, or moved is unambiguous staleness — fix it (see step 5).

### 4. Drill into drifted docs

For each doc with a non-empty change set from step 2:

- Read the relevant changed files at `origin/main` and the commits in the change set (`git -C "$VSCODE_REPO" show <sha>`) for context on what changed and why.
- Compare against the doc's description. Decide: still accurate, partially stale, or substantially stale.

### 5. Update docs in place

For each doc that needs changes (from steps 3 or 4):

- Update the body to match the current state of the code.
- Update `Covers:` if the relevant paths shifted.
- Update or remove inline references to deleted/renamed/moved symbols.
- Append a new changelog entry:

  ```markdown
  - **YYYY-MM-DD** — <origin/main HEAD short SHA, via `git -C "$VSCODE_REPO" rev-parse --short=10 origin/main`> — reconciliation: <one-line summary of what was updated>
  ```

  The new SHA becomes the new baseline for next time.

If a doc has been *substantially* invalidated (the component it describes has been split, merged, or deleted), do not silently rewrite it — surface it to the user and ask whether to rewrite, split, or delete the doc.

### 6. Report

Once updates are written, summarize:

- **Reconciled:** which docs were updated, and which VS Code commits drove each update.
- **Presumed current:** count of docs with no changes since baseline. (List them only if the user asks.)
- **Needs human attention:** docs flagged for substantial invalidation in step 5.

Do not commit. Tell the user the diff is ready for review at `$KNOWLEDGE_CHECKOUT`.
