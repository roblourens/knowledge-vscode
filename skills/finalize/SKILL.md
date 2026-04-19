---
name: finalize
description: "Roll what was learned in this session back into the VS Code agent host knowledge repo. Use when the user says 'finalize knowledge', 'finalize the session', 'capture what we learned', or has finished implementing a change and wants the docs and changelog updated. Pulls latest from origin/main, writes doc updates, a new changes/ entry, and cleans up the session's plan/ subfolder. Does NOT commit, push, or merge — leaves the diff for the user to review, then 'land' to publish it."
---

# Skill: finalize

Capture what was learned in this session as on-disk changes in the knowledge repo, ready for the user to review and commit.

This skill **does not commit, push, merge, or remove worktrees**. The only on-disk deletion it performs is removing the session's `plan/` subfolder. Everything else is the user's call after reviewing the diff — once they're happy, the `land` skill publishes it.

## Precondition

Knowledge repo must be set up. If `$VSCODE_REPO/.knowledge` doesn't exist as a symlink, or doesn't resolve, run `init` first.

Re-derive what you need each time:

- `KNOWLEDGE_CHECKOUT = "$VSCODE_REPO/.knowledge"` (the symlink path itself; don't dereference it)
- `VSCODE_REPO`, `VSCODE_BRANCH` from `git rev-parse` against the workspace root.
- `SESSION_SLUG`: the single subfolder under `$KNOWLEDGE_CHECKOUT/plan/`. If there are zero (the session never went through `plan` or `implement`), generate one now (`YYYY-MM-DD-<short-description>`). If there are multiple, ask the user.

## Workflow

### 0. Sync with upstream

Before writing anything, pull the latest knowledge state into the session worktree so this session's edits land on top of any work other sessions have published since `init` ran:

```sh
cd "$KNOWLEDGE_CHECKOUT"
git fetch origin main
git merge --ff-only origin/main
```

The ff-merge should always succeed: the session branch was created from `main` at `init` time and no skill commits to it before `finalize`. If it fails (e.g. the user committed something on the branch by hand, or the working tree has conflicting uncommitted changes), stop and tell the user — don't try to resolve it.

### 1. Retrospective — what went wrong, and what would have prevented it

**This is the most important step. Do it before writing anything else.** The point of the knowledge base is to make the *next* session avoid the mistakes of *this* one. If a finalize doesn't surface those mistakes, the knowledge base doesn't compound.

Read the full conversation history of this session and the `## Discoveries for finalize` section of `tasks.md` (if `implement` was used). Look explicitly for:

- **Wrong initial assumptions** — what did you (or the user) initially believe about the code that turned out to be false? What made you believe it? (Misleading doc, misleading symbol name, misleading comment, plausible-but-wrong analogy from another part of the codebase.)
- **Dead ends** — approaches you tried, partially built, and then abandoned. Why did they fail? What signal would have told you upfront that they wouldn't work?
- **Surprises** — behaviour that was not what the docs (or the code's surface area) suggested. Hidden coupling, undocumented preconditions, non-obvious ordering requirements, side effects you didn't expect.
- **Re-discoveries** — things you had to figure out by reading code that *should* have been in a doc or a `gotcha:` entry. If a previous session encountered the same thing and didn't write it down, that's a pattern.
- **Tooling / workflow misses** — wrong test command, wrong launch config, slow feedback loop, useful command you didn't know existed until late.
- **Spec / protocol misreads** — places where the wire contract or generated types didn't match what the code actually does at runtime.

For each item, answer: **what specific addition or change to the knowledge base would have prevented this, and where does it belong?** Map each item to one of:

- A **`gotcha:`** entry on a specific doc (load-bearing weirdness someone would naively "fix" and break).
- A **`debt:`** entry on a specific doc (something that genuinely is wrong and should be cleaned up).
- A **doc body update** (the description of how the component works was incomplete or misleading — including any prescriptive "how to work with this" notes that belong with the component).
- A **new doc** (no doc covers this area at all; that's why it bit you).
- A **`changes/` summary** entry (decision rationale or narrative that doesn't fit anywhere else, but the next person looking at this area should read it).

Write this mapping down somewhere durable for the rest of finalize to consume — either in your reasoning, or as a scratch list. Steps 2–5 are *executing* on this mapping, not generating it from scratch.

If the session genuinely had no missteps and the existing docs were accurate enough that the work went smoothly, say so explicitly to the user — that's a useful signal too — and skip ahead to step 5 (the `changes/` summary). But err strongly on the side of finding something: "the work went smoothly" is rarely true on inspection.

Note: things like decisions and their rationale belong in `changes/`, not `docs/`. Things about how a component currently works belong in `docs/`. Things to revisit or preserve carefully belong in `## Debt & gotchas`.

### 2. Update existing docs

For each existing doc in `$KNOWLEDGE_CHECKOUT/docs/` whose subject area was changed by this session:

- Revise the doc body to reflect the new state.
- Update the `Covers:` line if the set of relevant paths changed.
- Update inline cross-references if relationships between components changed.
- Update the `## Debt & gotchas` section (see step 2a).
- Append a changelog entry to the doc's changelog section:

  ```markdown
  - **YYYY-MM-DD** — <SHA> — <one-line description of what changed>
  ```

  Use the current HEAD of `$VSCODE_BRANCH` for the SHA, abbreviated to 10 characters: `git -C "$VSCODE_REPO" rev-parse --short=10 HEAD`.

### 2a. Update Debt & gotchas

Review the conversation (and any `## Discoveries for finalize` notes left by `implement` in `tasks.md`) for things to record. Each doc has a `## Debt & gotchas` section between the body and the changelog — add or remove bullets as warranted.

Three triggers:

- **Resolved debt:** if this session fixed something a doc's `debt:` entry called out, **remove** the entry.
- **New debt:** if you noticed something that looks wrong, is duplicated, is mid-migration, or should be revisited later — add a `debt:` entry.
- **New gotcha:** if you discovered something is the way it is on purpose and a future agent could easily break it by "cleaning it up" — add a `gotcha:` entry. Be deliberate; gotchas are presumed permanent.

Format (one bullet line):

```markdown
- **debt** (YYYY-MM-DD, <file:symbol>) — <one-line description of what's wrong and ideally how to fix>
- **gotcha** (YYYY-MM-DD, <file:symbol>) — <what's load-bearing and what a future change should preserve>
```

If no `## Debt & gotchas` section exists in a doc that needs an entry, add one between the body and the `## Changelog`.

If the new item is **cross-cutting** (spans multiple docs / affects how to work across the subsystem), also add a one-line pointer under `## Active debt & gotchas` in `$KNOWLEDGE_CHECKOUT/index.md` referencing the doc(s) where the detail lives. Don't duplicate the detail — just point.

### 3. Create new docs if needed

If something material was learned about a component that has no doc yet, create one under `$KNOWLEDGE_CHECKOUT/docs/<descriptive-name>.md`:

```markdown
# <Component name>

_Covers: <vscode-relative path 1>, <path 2>, ..._

<body — what it is, how it works, key files/classes/functions, how it relates to other components, with inline links to related docs as `[name](./other-doc.md)`>

## Debt & gotchas

_(Empty for now. Entries take the form `- **debt|gotcha** (YYYY-MM-DD, file:symbol) — description`.)_

## Changelog

- **YYYY-MM-DD** — <SHA> — initial entry
```

For the initial SHA: if the doc describes existing state in the VS Code repo, use the current HEAD of `origin/main` (`git -C "$VSCODE_REPO" rev-parse --short=10 origin/main`). If it describes something that's part of an in-flight change on the current branch, use the current HEAD of `$VSCODE_BRANCH` (`git -C "$VSCODE_REPO" rev-parse --short=10 HEAD`). When in doubt, use the branch HEAD. Always abbreviate to 10 characters.

Add a one-line entry to `$KNOWLEDGE_CHECKOUT/index.md` under **Docs** with the doc's name, a keyword-rich one-line description, and its `Covers:` paths.

### 4. Write the change entry

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

## What went wrong or was misunderstood
The retrospective from step 1, distilled. One bullet per misstep, dead end, wrong assumption, or surprise. Each bullet pairs the mistake with what would have prevented it and where that prevention now lives:

- <what went wrong / what was assumed vs. what was true> — **prevented by:** <`gotcha:` on doc X | `debt:` on doc Y | doc body update on Z | new doc N | this summary>.
- ...

If the session truly had no missteps, write `- (none — existing knowledge was sufficient)` and explain briefly why this area was already well-covered.

## What we learned
- <other noteworthy things that don't fit above — e.g. observations about the agent host itself, the workflow, or tooling, that aren't tied to a specific mistake>

## Doc updates
- <list of docs updated or created in this session, including which `## Debt & gotchas` entries were added or removed>
```

The **What went wrong** section is mandatory — even if short. It is the durable artifact of step 1. The whole point of finalize is that the next session avoids these mistakes, which only works if they're written down.

### 5. Clean up the plan

Delete the session's plan folder: `rm -rf "$KNOWLEDGE_CHECKOUT/plan/$SESSION_SLUG"`. (This is the only deletion this skill performs.)

### 6. Report the diff

Run `git -C "$KNOWLEDGE_CHECKOUT" status` and `git -C "$KNOWLEDGE_CHECKOUT" diff --stat` and surface the result to the user. Tell them:

- What files were created, modified, deleted.
- The path to `$KNOWLEDGE_CHECKOUT` so they can review the diff in their editor (also accessible as `.knowledge/` inside the VS Code worktree).
- Once they're happy with the diff, the `land` skill commits it, fast-forward-merges into `main`, pushes, and tears down the session worktree.

Do not run `git add`, `git commit`, `git push`, `git merge`, `git worktree remove`, or `rm` on the `.knowledge` symlink. That is `land`'s job.
