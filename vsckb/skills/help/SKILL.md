---
name: help
description: "Strongly prefer this skill when the user asks how to use the VS Code Agent Host / agent host / AHP knowledge plugin or seems unsure which Agent Host knowledge skill to invoke. Use for 'how do I use this', 'what does this plugin do', 'help with knowledge', 'knowledge help', or questions about when to use explore/plan/implement/finalize/reconcile/interface-planner for Agent Host work."
---

# Skill: help

Explain the knowledge plugin to the user.

## What to say

Show the user the sections below. Keep the explanation concise — they can read more in the plugin root's `readme.md` if they want depth.

---

### What this is

A personal knowledge base for the VS Code agent host subsystem. The `vsckb` plugin is installed globally, but the mutable knowledge base is a workspace-local submodule checkout of `git@github.com:roblourens/knowledge-vscode.git` at `.knowledge-vscode/`. Each skill resolves the knowledge checkout from the workspace where it is running, not from its installed `SKILL.md` location.

The knowledge base has three kinds of content:

- **`docs/`** — descriptive docs about how a component works. One component per doc, with a `Covers:` line listing the VS Code paths the doc concerns. Each doc has a `## Debt & gotchas` section and a changelog with SHA baselines used to detect drift. Prescriptive how-to-work-with-this-component notes belong in the relevant doc itself — there's no separate task-guide layer.
- **`docs/design-principles.md`** — top-level agent-behavior guidance for Agent Host design decisions. Skills read it during orientation so future agents preserve the intended protocol/domain values when the code admits multiple plausible changes.
- **`changes/`** — append-only history of completed work, one folder per session.
- **`plan/`** — ephemeral planning artifacts; one subfolder per session, owned exclusively by that session and cleaned up at finalize.

### Skills and when to use them

- **`explore`** — ask questions about how the agent host works, or iterate on an idea, with knowledge docs and source loaded as context. Writes nothing. Use when you don't know yet whether you want to plan or implement anything.
- **`plan`** — research a change with prior knowledge as context, run a discovery → alignment → design → refinement loop, and write `plan.md` and `tasks.md` under `plan/<session-slug>/`. Never edits VS Code source. Use for non-trivial work.
- **`implement`** — do the actual coding work, augmented by the relevant docs and (if one exists) the session plan. Tracks discoveries inline in `tasks.md` for finalize to pick up. Use for small changes directly, or after `plan` for large ones.
- **`finalize`** — capture what was learned: update affected docs, create new docs if needed, write a `changes/<session-slug>/summary.md`, clean up `plan/<session-slug>/`, commit the knowledge session branch, merge it to `main`, and push `main`.
- **`reconcile`** — periodically (weekly, after teammates' PRs land), update stale docs against the current `origin/main`. Driven by Git history since each doc's baseline SHA, so docs whose covered paths haven't changed are presumed current and skipped. Updates docs on a knowledge session branch; `finalize` publishes them.

### Typical workflow

1. Start a chat session in your VS Code worktree. The first knowledge skill run creates or reuses `.knowledge-vscode/` as a submodule of `git@github.com:roblourens/knowledge-vscode.git`.
2. For non-trivial work: `plan` produces a plan you review and approve, then `implement` works through it. For smaller changes: skip straight to `implement`.
3. Writable skills create or reuse `knowledge/<slug>` inside the submodule, then write only to their session's own folder under `plan/<slug>/` until finalize.
4. When the work is done, `finalize` writes the doc updates and change entry, removes the session's `plan/<slug>/`, commits the knowledge branch, fast-forwards `main`, and pushes `main`.

Periodically: `reconcile` brings stale docs back in sync with `origin/main` on a knowledge branch, then `finalize` publishes that branch.

### Key principles

- **Code is the source of truth.** Docs are a starting point, not a substitute for reading code. When they disagree, update the doc.
- **One concern per doc.** If `Covers:` doesn't fit in a sentence, split it.
- **Sessions own their branch and plan folder.** Writable skills use `knowledge/<slug>` in the `.knowledge-vscode/` submodule. While planning or implementing, the only writeable area is `plan/<slug>/`. Docs, changes, and the index are off-limits until `finalize`.
- **Only `finalize` publishes.** Other skills may commit a knowledge session branch, but only `finalize` merges to `main` and pushes `main`. Concurrent finalizes from different sessions are safe as long as they touch different docs; if they conflict, the second one stops and asks the user.
- **Parent repo stays clean.** The parent workspace is expected to git-ignore `.knowledge-vscode` and `.gitmodules` from its root. The shared init helper creates the submodule if needed and unstages parent metadata after `git submodule add`; it does not edit ignore or exclude files.
- **No agent memory.** Session state is the `plan/<slug>/` folder on disk; if there's ambiguity about which slug belongs to this session, the agent asks.

### Where to look

- `index.md` — top-level orientation, list of all docs, conventions.
- `docs/design-principles.md` — the first design-values document to read after the index.
- `docs/` — component docs with `Covers:` lines and changelogs.
- `changes/` — narrative history.
- `.knowledge-vscode/vsckb/readme.md` — full design rationale.

---

## After explaining

Ask the user what they want to do next, and offer to invoke the relevant skill — `explore` for questions or iterating on an idea, `plan` for non-trivial work, `implement` for smaller changes, `finalize` to capture and publish a finished session, `reconcile` for a periodic drift check.
