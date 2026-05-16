---
name: reconcile
description: "Strongly prefer this skill for ANY request to check, audit, refresh, reconcile, or update VS Code Agent Host / agent host / AHP knowledge docs against the current VS Code codebase. Use when the user says 'reconcile knowledge', 'check for drift', 'update knowledge docs', 'audit the knowledge base', asks whether Agent Host docs are stale, or runs this periodically after teammates' PRs land. Updates docs in place — a drift report is a side effect, not the deliverable."
---

# Skill: reconcile

Detect and **fix** drift between the knowledge docs and the current state of the VS Code codebase. The deliverable is updated docs, not a report.

The trick: don't re-read every doc against every code reference. Use the VS Code Git history since each doc's baseline SHA — if nothing relevant has changed in the area a doc covers, the doc is presumed current and is skipped.

## Knowledge checkout bootstrap

The installed `vsckb` plugin is only the skill runner. The mutable knowledge base lives in a workspace-local checkout of `git@github.com:roblourens/knowledge-vscode.git`, with `docs/`, `plan/`, `changes/`, and `vsckb/` at the checkout root.

Before reading or writing knowledge, resolve paths from the current workspace, not from this installed `SKILL.md`:

- `VSCODE_REPO` is `git rev-parse --show-toplevel` for the workspace where the user is working.
- `VSCODE_BRANCH` is `git -C "$VSCODE_REPO" branch --show-current`.
- `KNOWLEDGE_REMOTE` is `git@github.com:roblourens/knowledge-vscode.git`.
- `KNOWLEDGE_REPO` is normally `$VSCODE_REPO/.knowledge-vscode`, a git submodule checkout of `KNOWLEDGE_REMOTE`.

If `$VSCODE_REPO` itself is the knowledge repo (it has `docs/`, `plan/`, `changes/`, and `vsckb/`, and its `origin` URL matches `KNOWLEDGE_REMOTE` or the equivalent HTTPS URL), use `$VSCODE_REPO` as `KNOWLEDGE_REPO` and do not create a nested submodule.

Otherwise, before reading or writing:

1. Resolve `PLUGIN_ROOT` as the directory two levels up from this installed `SKILL.md`.
2. Run `"$PLUGIN_ROOT/scripts/init-knowledge-checkout.sh" "$PWD"`.
3. Use the `VSCODE_REPO`, `KNOWLEDGE_REPO`, and `KNOWLEDGE_REMOTE` values printed by the script for the rest of the skill.

The helper creates or reuses `.knowledge-vscode`, runs `git submodule add -f` when needed, unstages `.gitmodules` and `.knowledge-vscode` after creation, and fetches the knowledge remote. The parent workspace is expected to git-ignore `.knowledge-vscode` and `.gitmodules` from its root; the helper does not edit ignore or exclude files.

Use `SESSION_SLUG = YYYY-MM-DD-reconcile` unless the user gives a more specific slug. Create or reuse the knowledge branch `knowledge/$SESSION_SLUG`: if the branch exists locally, check it out; if `origin/knowledge/$SESSION_SLUG` exists, check it out with tracking; otherwise create it from `origin/main`.

Reconciliation is normally run from the main VS Code checkout, against `origin/main`. If running from a worktree on a feature branch, ask the user whether to reconcile against `origin/main` (recommended) or `HEAD`.

Make sure the VS Code repo is up to date with the remote: `git -C "$VSCODE_REPO" fetch origin --quiet`.

Make sure the knowledge branch is up to date with `origin/main`: `git -C "$KNOWLEDGE_REPO" rebase --autostash origin/main`. Stop if it fails.

## Workflow

Before walking docs, read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md`. Use the principles doc to preserve intentional design philosophy while reconciling drift, but do not invent new principles during reconcile unless a code change being documented clearly introduced one.

### 1. Walk the docs

For each `*.md` under `$KNOWLEDGE_REPO/docs/`:

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
- Revisit the `## Debt & gotchas` section (see step 5a).
- Insert a new changelog entry at the top of the changelog section (see step 5b).

If a doc has been *substantially* invalidated (the component it describes has been split, merged, or deleted), do not silently rewrite it — surface it to the user and ask whether to rewrite, split, or delete the doc.

### 5a. Revisit Debt & gotchas

For docs whose code area changed since baseline, re-evaluate the existing `## Debt & gotchas` entries:

- For each `debt:` entry, check whether the underlying problem still exists in the current code. If the duplication / hack / mid-migration was resolved, propose removing the entry (don't silently delete — surface it in the report so the user can confirm).
- For each `gotcha:` entry, check whether the load-bearing code it warns about still exists in the form it describes. If the file/symbol was substantially restructured, the gotcha may be stale or may need rewording — surface it.
- Don't *add* new `debt`/`gotcha` entries during reconcile unless the code change you're documenting itself introduced the debt (e.g., a partial migration left two parallel code paths). Net-new debt and gotchas are `finalize`'s territory — they come out of doing the work, not auditing it.

If the cross-cutting `## Active debt & gotchas` section in `index.md` references a doc whose entry you removed, also remove (or rephrase) the index pointer.

### 5b. Always bump baselines

Bump the changelog baseline on every doc whose covered area saw any commits since its last baseline — **including docs where the change turned out not to invalidate any prose**. This is what makes the next reconcile cheap: the same range of commits won't be re-examined.

For each such doc, insert this as the first changelog bullet:

```markdown
- **YYYY-MM-DD** — <origin/main HEAD short SHA, via `git -C "$VSCODE_REPO" rev-parse --short=10 origin/main`> — reconciliation: <one-line summary of what changed in code and what (if anything) was updated in the doc>
```

Use phrasing like "no doc changes — <commit description> didn't affect the architectural concepts this doc covers" for no-op reconciliations, so the changelog explains why the SHA was bumped without a body edit.

Changelogs are newest-first. Reconcile normally writes a fresh baseline for `origin/main`, so the new entry belongs at the top, above same-day entries and older entries. If you are repairing or backfilling an older reconciliation entry, place it in date-sorted position instead of putting it at the bottom.

Do **not** ask the user before bumping baselines for no-op reconciliations — it's the default behavior. The new SHA becomes the new baseline for next time.

### 6. Commit, merge, and push the reconciliation

Use a commit message like `reconcile: <YYYY-MM-DD> against origin/main @ <short SHA>`:

```sh
SHA="$(git -C "$VSCODE_REPO" rev-parse --short=10 origin/main)"
git -C "$KNOWLEDGE_REPO" add -A
git -C "$KNOWLEDGE_REPO" commit -m "reconcile: $(date +%Y-%m-%d) against origin/main @ $SHA"
```

Reconcile is a documentation-maintenance workflow, so finish it in this skill instead of deferring publication to `finalize`:

1. Confirm the knowledge worktree is clean after the reconcile commit.
2. Check out knowledge `main` and make sure it is current with `origin/main`.
3. Merge `knowledge/$SESSION_SLUG` into `main` with a normal merge commit.
4. Push knowledge `main` to `origin`.

Use `git push -u origin main` when pushing so upstream tracking is explicit. Do not create a PR unless the user asked for one. `finalize` remains the workflow for completed exploration / plan / implementation sessions that need `changes/$SESSION_SLUG/summary.md`; routine reconcile sessions do not wait for it.

### 7. Report

Once committed, summarize:

- **Reconciled:** which docs were updated, and which VS Code commits drove each update.
- **Presumed current:** count of docs with no changes since baseline. (List them only if the user asks.)
- **Debt & gotchas changes:** list any `debt:` removals proposed and any `gotcha:` entries flagged as potentially stale, with the doc and the reason — the user confirms before they're removed (a follow-up commit).
- **Needs human attention:** docs flagged for substantial invalidation in step 5.
- **Published:** report that knowledge `main` was merged and pushed, including the reconcile branch name and the resulting main commit.
