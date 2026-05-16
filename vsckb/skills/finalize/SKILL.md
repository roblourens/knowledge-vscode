---
name: finalize
description: "Strongly prefer this skill after ANY completed VS Code Agent Host / agent host / AHP / Agent Host Protocol exploration, plan, or implementation when the user wants learnings captured, docs updated, or knowledge finalized. Use when the user says 'finalize knowledge', 'finalize the session', 'capture what we learned', or has finished Agent Host work and wants docs/changelog updated. Updates docs and changes/, cleans up the session's plan/ subfolder, then commits the knowledge session branch, merges it to main, and pushes main."
---

# Skill: finalize

Capture what was learned in this session as updates to the knowledge repo, then commit the knowledge session branch, merge it to `main`, and push `main`.

This skill writes doc updates, a new `changes/` entry, removes the session's `plan/` subfolder, and commits the lot. It is the only skill in this plugin that writes outside `plan/<slug>/` or merges and pushes `main`.

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

## Pick the session slug

`SESSION_SLUG` is the session's subfolder under `$KNOWLEDGE_REPO/plan/`. If `plan`, `implement`, `interface-planner`, or `reconcile` ran earlier in this conversation, reuse the slug they used. Otherwise:

- If exactly one folder under `plan/` looks like this session's work, use it.
- If multiple folders are present (concurrent sessions in other VS Code windows), ask the user which slug belongs to this session — don't guess.
- If none exist (the session never went through `plan` or `implement`), generate one now: `YYYY-MM-DD-<short-description>`.

## Workflow

Before step 1, create or checkout the knowledge branch `knowledge/$SESSION_SLUG`: if the branch exists locally, check it out; if `origin/knowledge/$SESSION_SLUG` exists, check it out with tracking; otherwise create it from `origin/main`.

### 1. Make sure the knowledge branch is clean enough

Check `git -C "$KNOWLEDGE_REPO" status --porcelain`. If there are uncommitted edits that don't belong to this session (e.g. another in-flight finalize, hand edits the user is working on), stop and surface them — do not commit them along with this session's work.

Exception: unrelated uncommitted `plan/<other-session>/` folders are common when another session is in progress. If the user confirms they are unrelated, you may ignore those folders and continue, but you must avoid `git add -A`; stage only this session's doc/change/plan cleanup files explicitly.

### 2. Sync the session branch with origin

```sh
git -C "$KNOWLEDGE_REPO" fetch origin main --quiet
git -C "$KNOWLEDGE_REPO" rebase --autostash origin/main
```

If the rebase fails (concurrent finalize from another session touched the same docs), stop and surface the conflict to the user. Don't attempt to auto-resolve prose conflicts.

### 3. Retrospective — what went wrong, and what would have prevented it

**This is the most important step. Do it before writing anything else.** The point of the knowledge base is to make the *next* session avoid the mistakes of *this* one. If a finalize doesn't surface those mistakes, the knowledge base doesn't compound.

Read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md` before the retrospective. Use the principles doc as a checklist: did this session reveal a new reusable principle, violate an existing one, or produce a decision that belongs in `changes/` rather than docs?

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

Steps 4–7 are *executing* on this mapping, not generating it from scratch.

If the session genuinely had no missteps and the existing docs were accurate enough that the work went smoothly, say so explicitly to the user — that's a useful signal too — and skip ahead to step 7 (the `changes/` summary). But err strongly on the side of finding something: "the work went smoothly" is rarely true on inspection.

Note: things like decisions and their rationale belong in `changes/`, not `docs/`. Things about how a component currently works belong in `docs/`. Things to revisit or preserve carefully belong in `## Debt & gotchas`.

### 4. Update existing docs

For each existing doc in `$KNOWLEDGE_REPO/docs/` whose subject area was changed by this session:

- Revise the doc body to reflect the new state.
- Update the `Covers:` line if the set of relevant paths changed.
- Update inline cross-references if relationships between components changed.
- Update the `## Debt & gotchas` section (see step 4a).
- Insert a changelog entry as the first bullet in the doc's changelog section:

  ```markdown
  - **YYYY-MM-DD** — <SHA> — <one-line description of what changed>
  ```

  Use the current HEAD of `$VSCODE_BRANCH` for the SHA, abbreviated to 10 characters: `git -C "$VSCODE_REPO" rev-parse --short=10 HEAD`. Changelogs are newest-first; normal finalize entries go above same-day entries and older entries. If you are backfilling an older dated entry, place it in date-sorted position instead of putting it at the bottom.

### 4a. Update Debt & gotchas

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

If the new item is **cross-cutting** (spans multiple docs / affects how to work across the subsystem), also add a one-line pointer under `## Active debt & gotchas` in `$KNOWLEDGE_REPO/index.md` referencing the doc(s) where the detail lives. Don't duplicate the detail — just point.

### 5. Create new docs if needed

If something material was learned about a component that has no doc yet, create one under `$KNOWLEDGE_REPO/docs/<descriptive-name>.md`:

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

Add a one-line entry to `$KNOWLEDGE_REPO/index.md` under **Docs** with the doc's name, a keyword-rich one-line description, and its `Covers:` paths.

### 6. Clean up the plan

Delete the session's plan folder: `rm -rf "$KNOWLEDGE_REPO/plan/$SESSION_SLUG"`.

### 7. Write the change entry

Create `$KNOWLEDGE_REPO/changes/$SESSION_SLUG/summary.md`:

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
The retrospective from step 3, distilled. One bullet per misstep, dead end, wrong assumption, or surprise. Each bullet pairs the mistake with what would have prevented it and where that prevention now lives:

- <what went wrong / what was assumed vs. what was true> — **prevented by:** <`gotcha:` on doc X | `debt:` on doc Y | doc body update on Z | new doc N | this summary>.
- ...

If the session truly had no missteps, write `- (none — existing knowledge was sufficient)` and explain briefly why this area was already well-covered.

## What we learned
- <other noteworthy things that don't fit above — e.g. observations about the agent host itself, the workflow, or tooling, that aren't tied to a specific mistake>

## Doc updates
- <list of docs updated or created in this session, including which `## Debt & gotchas` entries were added or removed>
```

The **What went wrong** section is mandatory — even if short.

### 8. Commit, merge, and push

Use the title from the `changes/$SESSION_SLUG/summary.md` first heading (without the leading `# `) as the commit subject:

```sh
SUBJECT="$(awk '/^# /{sub(/^# /,""); print; exit}' "$KNOWLEDGE_REPO/changes/$SESSION_SLUG/summary.md")"
git -C "$KNOWLEDGE_REPO" add -A
git -C "$KNOWLEDGE_REPO" commit -m "$SUBJECT"
git -C "$KNOWLEDGE_REPO" checkout main
git -C "$KNOWLEDGE_REPO" pull --rebase origin main
git -C "$KNOWLEDGE_REPO" merge --ff-only "knowledge/$SESSION_SLUG"
git -C "$KNOWLEDGE_REPO" push origin main
```

If step 1 identified unrelated plan folders that the user asked you to ignore, do not use `git add -A` here. Stage the specific files for this finalize (updated docs, `changes/$SESSION_SLUG/summary.md`, deleted `plan/$SESSION_SLUG/`, and any intentional skill updates) and verify `git diff --cached --name-status` does not include the unrelated plan folders before committing.

If `main` advanced between steps 2 and 8 and the fast-forward merge fails, checkout `knowledge/$SESSION_SLUG`, re-run step 2's rebase, then retry the checkout-main, pull, merge, and push sequence once. If it still fails, stop and surface to the user.

Do not push the session branch unless the user explicitly asks. The durable published state is `main` on the knowledge remote.

### 9. Report

Tell the user:

- The committed SHA (`git -C "$KNOWLEDGE_REPO" rev-parse --short=10 HEAD`).
- Which docs were created/modified and which `## Debt & gotchas` entries were added or removed.
- That `plan/$SESSION_SLUG/` is gone.

If the work needs amending later, the user can edit `$KNOWLEDGE_REPO` directly and make a follow-up commit.
