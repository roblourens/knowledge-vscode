---
name: implement
description: "Implement a change to the VS Code agent host, using prior knowledge as context. Use when the user asks to 'implement' a feature/change in the agent host, 'work on' a planned task, or says 'knowledge implement'. If a plan exists for this session under the knowledge repo, follow it; otherwise read relevant docs and proceed from the user's prompt."
---

# Skill: implement

Implement a change to the VS Code agent host, augmented by prior knowledge from the knowledge repo. This skill is deliberately lightweight — it's the normal agent coding workflow with knowledge context loaded up front.

## Knowledge repo location

This `SKILL.md` lives at `<KNOWLEDGE_REPO>/vsckb/skills/implement/SKILL.md`. Resolve `KNOWLEDGE_REPO` as the directory three levels up from this file. All knowledge reads and writes happen against that path directly.

Re-derive `VSCODE_REPO` and `VSCODE_BRANCH` from `git rev-parse` against the workspace root.

## Write boundary in the knowledge repo

While implementing, the only files you may create or modify in the knowledge repo are under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`. Do not touch `docs/`, `changes/`, `index.md`, or other sessions' `plan/` folders. Doc updates and history entries happen at `finalize`. Concurrent sessions write to disjoint slugs.

## Workflow

### 1. Pick up or create the session slug

If `plan` ran earlier in this conversation, reuse the `SESSION_SLUG` it created. Otherwise:

- If the user is resuming work and tells you the slug, use it.
- If exactly one folder under `$KNOWLEDGE_REPO/plan/` looks like this session's, use it.
- Otherwise generate one: `SESSION_SLUG = YYYY-MM-DD-<short-description>`. If that path already exists, append `-2`, `-3`, etc. until free. `mkdir -p "$KNOWLEDGE_REPO/plan/$SESSION_SLUG"`.

The empty folder is enough to mark the session for `finalize`. You don't need to write `plan.md`/`tasks.md` if there's no plan.

### 2. Load context

Read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md` before choosing implementation shape. The principles doc is agent-behavior guidance: apply it when the code and component docs leave more than one plausible path.

If `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/plan.md` exists:

- Read both `plan.md` and `tasks.md` in full.
- Re-read every doc listed under "Knowledge context used" in `plan.md`. The plan shouldn't be trusted to summarize them perfectly; the docs are the source of truth.
- Work through `tasks.md` in order, respecting declared dependencies.

If no plan exists:

- Identify which docs and tasks in `$KNOWLEDGE_REPO/index.md` overlap with the user's request, and read them before starting.
- Skim the most recent two or three `changes/` entries that touch the same subsystem.

### 3. Implement

Edit files in `$VSCODE_REPO`, run tests, iterate. Re-read the relevant docs (including any prescriptive how-to-work-with-this notes inside them) whenever you hit a recurring concern.

**As you go, keep `tasks.md` current.** If a `tasks.md` exists for this session, after completing each task update it in place: check the task off (`- [x] ...`) and add a short inline note for any deviation from the plan (e.g. `- note: implemented as X instead of Y because Z`). Don't batch this to the end — keep the file in sync with reality task by task. This is what `finalize` reads to write the change summary, and it lets the user see progress at a glance.

If during implementation you discover that a knowledge doc is wrong or incomplete, **do not fix it now** — note the discrepancy at the bottom of the session's `tasks.md`:

```markdown
## Discoveries for finalize
- <doc name>: <what's wrong / missing / surprising>
- debt: <file:symbol> — <what looks wrong / could be cleaned up / needs revisiting>
- gotcha: <file:symbol> — <what's load-bearing here that a future change must preserve>
- resolved-debt: <doc name> — <which existing `debt:` entry this session fixed>
```

`finalize` will use this list when updating docs and the per-doc `## Debt & gotchas` sections. Be deliberate about `gotcha:` — only add when you've found something genuinely load-bearing that someone would naively "clean up" and break.

### 4. Stop at "implementation complete"

This skill does not commit, push, or finalize. When the user is satisfied with the implementation, they (or the agent at their direction) run `finalize` to roll learnings back into the knowledge repo and commit them.

## Privacy: don't leak the knowledge repo into source

The knowledge repo is **private to the user**. Other contributors to the VS Code repo do not have access to it.

When writing code, comments, commit messages, PR descriptions, or any other artifact that lands in the public VS Code repo, **never reference**:

- The knowledge repo by name or path (e.g. `knowledge-vscode`, `$KNOWLEDGE_REPO`).
- Any doc inside it (e.g. `docs/agent-host-topology.md`, `docs/agent-host-sessions-providers.md`).
- Concepts whose only home is the knowledge repo (e.g. "agent-host topology", "well-known property names" as a knowledge-repo doc heading) phrased in a way that implies a doc the reader can look up.

Instead, inline whatever context the source code needs. If you'd otherwise want to write *"see docs/X.md for the broader story"*, replace it with a self-contained explanation in the code.

This applies the same way to `plan` and `finalize` outputs that land in the public repo (e.g. PR descriptions written from `tasks.md`). Files inside the knowledge repo itself (`plan/<session>/plan.md`, `tasks.md`, `docs/*.md`, `changes/*.md`) are private and may freely cross-reference each other.
