---
name: finalize
description: "Roll what was learned in this session back into the VS Code agent host knowledge repo. Use when the user says 'finalize knowledge', 'finalize the session', 'capture what we learned', or has finished implementing a change and wants the docs and changelog updated. Writes doc updates, a new changes/ entry, and cleans up the session's plan/ subfolder. Does NOT commit, push, or merge — leaves the diff for the user to review."
---

# Skill: finalize

Capture what was learned in this session as on-disk changes in the knowledge repo, ready for the user to review and commit.

This skill **does not commit, push, merge, or remove worktrees**. The only on-disk deletion it performs is removing the session's `plan/` subfolder. Everything else is the user's call after reviewing the diff.

## Precondition

Knowledge repo must be set up. If `$VSCODE_REPO/.knowledge` doesn't exist as a symlink, or doesn't resolve, run `init` first.

Re-derive what you need each time:

- `KNOWLEDGE_CHECKOUT = "$VSCODE_REPO/.knowledge"` (the symlink path itself; don't dereference it)
- `VSCODE_REPO`, `VSCODE_BRANCH` from `git rev-parse` against the workspace root.
- `SESSION_SLUG`: the single subfolder under `$KNOWLEDGE_CHECKOUT/plan/`. If there are zero (the session never went through `plan` or `implement`), generate one now (`YYYY-MM-DD-<short-description>`). If there are multiple, ask the user.

## Workflow

### 1. Take stock

Review the conversation history and any notes left under `$KNOWLEDGE_CHECKOUT/plan/$SESSION_SLUG/` (especially the "Discoveries for finalize" section in `tasks.md`). Identify:

- New understanding about components that should be added to or revised in existing docs.
- Context that was missing from the knowledge base but turned out to be relevant — things you had to discover by reading code, that should be documented for future sessions.
- Decisions made and their rationale (these belong in `changes/`, not `docs/`).

If nothing in the session changed how the codebase works *or* how we understand it, you can skip steps 2–4 and just write the `changes/` entry.

### 2. Update existing docs

For each existing doc in `$KNOWLEDGE_CHECKOUT/docs/` whose subject area was changed by this session:

- Revise the doc body to reflect the new state.
- Update the `Covers:` line if the set of relevant paths changed.
- Update inline cross-references if relationships between components changed.
- Append a changelog entry to the doc's changelog section:

  ```markdown
  - **YYYY-MM-DD** — <SHA> — <one-line description of what changed>
  ```

  Use the current HEAD of `$VSCODE_BRANCH` for the SHA, abbreviated to 10 characters: `git -C "$VSCODE_REPO" rev-parse --short=10 HEAD`.

### 3. Create new docs if needed

If something material was learned about a component that has no doc yet, create one under `$KNOWLEDGE_CHECKOUT/docs/<descriptive-name>.md`:

```markdown
# <Component name>

_Covers: <vscode-relative path 1>, <path 2>, ..._

<body — what it is, how it works, key files/classes/functions, how it relates to other components, with inline links to related docs as `[name](./other-doc.md)`>

## Changelog

- **YYYY-MM-DD** — <SHA> — initial entry
```

For the initial SHA: if the doc describes existing state in the VS Code repo, use the current HEAD of `origin/main` (`git -C "$VSCODE_REPO" rev-parse --short=10 origin/main`). If it describes something that's part of an in-flight change on the current branch, use the current HEAD of `$VSCODE_BRANCH` (`git -C "$VSCODE_REPO" rev-parse --short=10 HEAD`). When in doubt, use the branch HEAD. Always abbreviate to 10 characters.

Add a one-line entry to `$KNOWLEDGE_CHECKOUT/index.md` under **Docs** with the doc's name, a keyword-rich one-line description, and its `Covers:` paths.

### 4. Create new task guides if needed

If during this session you developed reusable guidance for a *kind of work* (not a specific component) that other sessions will likely benefit from — e.g., "how to do X", "what tests to write for Y" — create a file under `$KNOWLEDGE_CHECKOUT/tasks/<descriptive-name>.md` and add an entry under **Tasks** in `index.md`.

Task guides do not need a `Covers:` line or changelog — they're prescriptive.

### 5. Write the change entry

Create `$KNOWLEDGE_CHECKOUT/changes/$SESSION_SLUG/summary.md`:

```markdown
# <Title — one line, matches the plan if there was one>

**Date:** YYYY-MM-DD
**VS Code branch:** <VSCODE_BRANCH>
**VS Code SHA at finalize:** <git -C $VSCODE_REPO rev-parse --short=10 HEAD>
**PR:** <link if known, otherwise "TBD">

## What was done
<paragraph or two summarizing the change>

## Key decisions
- <decision and rationale>
- ...

## What we learned
- <anything noteworthy that future sessions should know — both about the agent host itself and about how the work went>

## Doc updates
- <list of docs updated or created in this session>
```

### 6. Clean up the plan

Delete the session's plan folder: `rm -rf "$KNOWLEDGE_CHECKOUT/plan/$SESSION_SLUG"`. (This is the only deletion this skill performs.)

### 7. Report the diff

Run `git -C "$KNOWLEDGE_CHECKOUT" status` and `git -C "$KNOWLEDGE_CHECKOUT" diff --stat` and surface the result to the user. Tell them:

- What files were created, modified, deleted.
- The path to `$KNOWLEDGE_CHECKOUT` so they can review the diff in their editor (also accessible as `.knowledge/` inside the VS Code worktree).
- That commit, merge, removal of the `.knowledge` symlink, and (if applicable) worktree cleanup are theirs to do.

Do not run `git add`, `git commit`, `git push`, `git merge`, `git worktree remove`, or `rm` on the `.knowledge` symlink.
