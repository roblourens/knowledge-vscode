---
name: implement
description: "Implement a change to the VS Code agent host, using prior knowledge as context. Use when the user asks to 'implement' a feature/change in the agent host, 'work on' a planned task, or says 'knowledge implement'. If a plan exists for this session under the knowledge repo, follow it; otherwise read relevant docs and proceed from the user's prompt."
---

# Skill: implement

Implement a change to the VS Code agent host, augmented by prior knowledge from the knowledge repo. This skill is deliberately lightweight — it's the normal agent coding workflow with knowledge context loaded up front.

## Precondition

Knowledge repo must be set up. If `$VSCODE_REPO/.knowledge` doesn't exist as a symlink, or doesn't resolve, run `init` first — automatically, without asking.

Re-derive what you need each time:

- `KNOWLEDGE_CHECKOUT = realpath "$VSCODE_REPO/.knowledge"`
- `SESSION_SLUG`: the single subfolder under `$KNOWLEDGE_CHECKOUT/plan/`. If there are zero, you'll create one in step 2 below. If there are multiple, ask the user which session this is.

## Workflow

### 1. Pick up the plan if one exists

If `$KNOWLEDGE_CHECKOUT/plan/$SESSION_SLUG/plan.md` exists:

- Read both `plan.md` and `tasks.md` in full.
- Re-read every doc and task guide listed under "Knowledge context used" in `plan.md`. The plan shouldn't be trusted to summarize them perfectly; the docs are the source of truth.
- Work through `tasks.md` in order, respecting declared dependencies.
- As tasks complete, update `tasks.md` in place by checking them off and noting any deviations from the plan inline (e.g., `- note: implemented as X instead of Y because Z`). This becomes useful context for `finalize`.

### 2. If no plan exists

- Identify which docs and tasks in `$KNOWLEDGE_CHECKOUT/index.md` overlap with the user's request, and read them before starting.
- Skim the most recent two or three `changes/` entries that touch the same subsystem.
- Generate a `SESSION_SLUG` (`YYYY-MM-DD-<short-description>`) and create `$KNOWLEDGE_CHECKOUT/plan/$SESSION_SLUG/` so `finalize` has a stable place to land. (You don't need to write `plan.md`/`tasks.md` — the empty folder is enough to mark the session.)
- Then proceed with normal implementation.

### 3. Implement

Edit files in `$VSCODE_REPO`, run tests, iterate. Refer back to task guides under `$KNOWLEDGE_CHECKOUT/tasks/` whenever you hit a recurring concern (e.g., test strategies, interactive verification, cross-repo coordination).

If during implementation you discover that a knowledge doc is wrong or incomplete, **do not fix it now** — note the discrepancy at the bottom of the session's `tasks.md`:

```markdown
## Discoveries for finalize
- <doc name>: <what's wrong / missing / surprising>
```

`finalize` will use this list when updating docs.

### 4. Stop at "implementation complete"

This skill does not commit, push, or finalize. When the user is satisfied with the implementation, they (or the agent at their direction) run `finalize` to roll learnings back into the knowledge repo.
