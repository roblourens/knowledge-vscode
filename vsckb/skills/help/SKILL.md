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

A personal knowledge base for the VS Code agent host subsystem. It lives in a separate Git repo (this plugin's repo) and is read/written directly — there's no worktree or symlink layer. Each skill resolves the repo path from its own `SKILL.md` location.

The knowledge base has three kinds of content:

- **`docs/`** — descriptive docs about how a component works. One component per doc, with a `Covers:` line listing the VS Code paths the doc concerns. Each doc has a `## Debt & gotchas` section and a changelog with SHA baselines used to detect drift. Prescriptive how-to-work-with-this-component notes belong in the relevant doc itself — there's no separate task-guide layer.
- **`docs/design-principles.md`** — top-level agent-behavior guidance for Agent Host design decisions. Skills read it during orientation so future agents preserve the intended protocol/domain values when the code admits multiple plausible changes.
- **`changes/`** — append-only history of completed work, one folder per session.
- **`plan/`** — ephemeral planning artifacts; one subfolder per session, owned exclusively by that session and cleaned up at finalize.

### Skills and when to use them

- **`explore`** — ask questions about how the agent host works, or iterate on an idea, with knowledge docs and source loaded as context. Writes nothing. Use when you don't know yet whether you want to plan or implement anything.
- **`plan`** — research a change with prior knowledge as context, run a discovery → alignment → design → refinement loop, and write `plan.md` and `tasks.md` under `plan/<session-slug>/`. Never edits VS Code source. Use for non-trivial work.
- **`implement`** — do the actual coding work, augmented by the relevant docs and (if one exists) the session plan. Tracks discoveries inline in `tasks.md` for finalize to pick up. Use for small changes directly, or after `plan` for large ones.
- **`finalize`** — capture what was learned: pull latest from `origin/main`, update affected docs, create new docs if needed, write a `changes/<session-slug>/summary.md`, clean up `plan/<session-slug>/`, commit the result, and push to `main`.
- **`reconcile`** — periodically (weekly, after teammates' PRs land), update stale docs against the current `origin/main`. Driven by Git history since each doc's baseline SHA, so docs whose covered paths haven't changed are presumed current and skipped. Updates docs in place and commits them.

### Typical workflow

1. Start a chat session in your VS Code worktree. Ask me to plan or implement something in the agent host.
2. For non-trivial work: `plan` produces a plan you review and approve, then `implement` works through it. For smaller changes: skip straight to `implement`.
3. `plan` and `implement` only ever write to their session's own folder under `plan/<slug>/`. Concurrent sessions in other windows are writing to different slugs and don't collide.
4. When the work is done, `finalize` writes the doc updates and change entry, removes the session's `plan/<slug>/`, and commits/pushes the result directly to `main`.

Periodically: `reconcile` brings stale docs back in sync with `origin/main`.

### Key principles

- **Code is the source of truth.** Docs are a starting point, not a substitute for reading code. When they disagree, update the doc.
- **One concern per doc.** If `Covers:` doesn't fit in a sentence, split it.
- **Sessions own their plan folder.** While planning or implementing, the only writeable area is `plan/<slug>/`. Docs, changes, and the index are off-limits until `finalize`.
- **Only `finalize` and `reconcile` commit.** Both pull-rebase before committing and push directly to `main`. Concurrent finalizes from different sessions are safe as long as they touch different docs; if they conflict, the second one stops and asks the user.
- **No agent memory.** Session state is the `plan/<slug>/` folder on disk; if there's ambiguity about which slug belongs to this session, the agent asks.

### Where to look

- `index.md` — top-level orientation, list of all docs, conventions.
- `docs/design-principles.md` — the first design-values document to read after the index.
- `docs/` — component docs with `Covers:` lines and changelogs.
- `changes/` — narrative history.
- The knowledge repo's root `readme.md` — full design rationale.

---

## After explaining

Ask the user what they want to do next, and offer to invoke the relevant skill — `explore` for questions or iterating on an idea, `plan` for non-trivial work, `implement` for smaller changes, `finalize` to capture and publish a finished session, `reconcile` for a periodic drift check.
