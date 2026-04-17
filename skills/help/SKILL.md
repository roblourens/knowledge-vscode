---
name: help
description: "Explain how to use the skills in this plugin and the overall workflow for working with the VS Code agent host knowledge base. Use when the user asks 'how do I use this', 'what does this plugin do', 'help with knowledge', 'knowledge help', or seems unsure which skill to invoke."
---

# Skill: help

Explain the knowledge plugin to the user.

## What to say

Show the user the sections below. Keep the explanation concise — they can read more in the repo's `readme.md` if they want depth.

---

### What this is

A personal knowledge base for the VS Code agent host subsystem. It lives in a separate Git repo (this plugin's repo) and is exposed inside the VS Code workspace as a `.knowledge/` symlink so files are easy to read and edit alongside the code.

The knowledge base has four kinds of content:

- **`docs/`** — descriptive docs about how a component works. One component per doc, with a `Covers:` line listing the VS Code paths the doc concerns. Each doc has a changelog with SHA baselines used to detect drift.
- **`tasks/`** — reusable how-to guides for recurring work patterns (test strategies, protocol updates, interactive verification).
- **`changes/`** — append-only history of completed work, one folder per session.
- **`plan/`** — ephemeral planning artifacts for the current session, cleaned up at finalize.

### Skills and when to use them

- **`init`** — sets up the knowledge repo for the current session: chooses a branch (usually mirroring the VS Code branch), creates a worktree if VS Code is in one, symlinks the checkout to `.knowledge/`, and excludes it from the VS Code repo's Git tracking. **You usually don't invoke this directly** — the other skills run it automatically when needed.
- **`explore`** — ask questions about how the agent host works, or iterate on an idea, with knowledge docs and source loaded as context. Writes nothing. Use when you don't know yet whether you want to plan or implement anything.
- **`plan`** — research a change with prior knowledge as context, run a discovery → alignment → design → refinement loop, and write `plan.md` and `tasks.md` under `plan/<session-slug>/`. Never edits VS Code source. Use for non-trivial work.
- **`implement`** — do the actual coding work, augmented by the relevant docs and (if one exists) the session plan. Tracks discoveries inline in `tasks.md` for finalize to pick up. Use for small changes directly, or after `plan` for large ones.
- **`finalize`** — capture what was learned: pull latest from `origin/main`, update affected docs, create new docs if needed, write a `changes/<session-slug>/summary.md`, clean up `plan/<session-slug>/`, and report the diff. **Does not commit.** You review the diff, then run `land`.
- **`land`** — commit the finalized edits, fast-forward-merge the session branch into `main`, push to `origin`, and tear down the session worktree + `.knowledge` symlink. Run after you've reviewed the diff `finalize` produced.
- **`reconcile`** — periodically (weekly, after teammates' PRs land), update stale docs against the current `origin/main`. Driven by Git history since each doc's baseline SHA, so docs whose covered paths haven't changed are presumed current and skipped. Updates docs in place; doesn't produce a report.

### Typical workflow

1. Start a chat session in your VS Code worktree. Ask me to plan or implement something in the agent host.
2. Behind the scenes, `init` runs once to set up `.knowledge/` for this session.
3. For non-trivial work: `plan` produces a plan you review and approve, then `implement` works through it. For smaller changes: skip straight to `implement`.
4. When the work is done, `finalize` writes the doc updates and change entry. You review the diff in `.knowledge/`. Once you're happy, `land` commits, ff-merges into `main`, pushes, and tears down the session worktree.

Periodically: `reconcile` brings stale docs back in sync with `origin/main`.

### Key principles

- **Code is the source of truth.** Docs are a starting point, not a substitute for reading code. When they disagree, update the doc.
- **One concern per doc.** If `Covers:` doesn't fit in a sentence, split it.
- **Skills don't auto-commit.** `finalize` and `reconcile` write changes and surface the diff; you review, then `land` (or commit by hand).
- **No agent memory.** Session state is re-derived from the filesystem (`.knowledge/` symlink + the single `plan/<slug>/` subfolder) on every skill invocation.
- **Branch + worktree per session.** Concurrent VS Code sessions — including the same task run with different models for comparison — get isolated knowledge branches so they can't influence each other mid-flight.

### Where to look

- `.knowledge/index.md` — top-level orientation, list of all docs and tasks, conventions.
- `.knowledge/docs/` — component docs with `Covers:` lines and changelogs.
- `.knowledge/changes/` — narrative history.
- The plugin's own `readme.md` — full design rationale.

---

## After explaining

Ask the user what they want to do next, and offer to invoke the relevant skill — `explore` for questions or iterating on an idea, `plan` for non-trivial work, `implement` for smaller changes, `finalize` to capture a finished session, `land` to publish a finalized session, `reconcile` for a periodic drift check.
