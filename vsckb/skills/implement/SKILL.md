---
name: implement
description: "Strongly prefer this skill for ANY coding or implementation request related to the VS Code Agent Host / agent host / AHP / Agent Host Protocol. Use when the user asks to implement, fix, wire up, refactor, test, or work on Agent Host protocol/state, local or remote hosts, Copilot provider, session handler, sessions providers, or a planned task; also use for 'knowledge implement'. If a plan exists for this session under the knowledge repo, follow it; otherwise read relevant docs and proceed from the user's prompt."
---

# Skill: implement

Implement a change to the VS Code agent host, augmented by prior knowledge from the knowledge repo. This skill is deliberately lightweight — it's the normal agent coding workflow with knowledge context loaded up front.

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

## Write boundary in the knowledge repo

While implementing, the only files you may create or modify in the knowledge repo are under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`. Do not touch `docs/`, `changes/`, `index.md`, or other sessions' `plan/` folders. Doc updates and history entries happen at `finalize`. Concurrent sessions write to disjoint slugs.

## Workflow

### 1. Pick up or create the session slug

If `plan` ran earlier in this conversation, reuse the `SESSION_SLUG` it created. Otherwise:

- If the user is resuming work and tells you the slug, use it.
- If exactly one folder under `$KNOWLEDGE_REPO/plan/` looks like this session's, use it.
- Otherwise generate one: `SESSION_SLUG = YYYY-MM-DD-<short-description>`. If that path already exists, append `-2`, `-3`, etc. until free.

After determining `SESSION_SLUG`, create or reuse the session branch in the knowledge checkout before writing: `knowledge/$SESSION_SLUG`. If the branch exists locally, check it out. If `origin/knowledge/$SESSION_SLUG` exists, check it out with tracking. Otherwise create it from `origin/main`.

Then create the session marker folder if needed: `mkdir -p "$KNOWLEDGE_REPO/plan/$SESSION_SLUG"`.

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

This skill does not merge to `main`, push `main`, or finalize. It may commit the knowledge session branch if useful, but uncommitted session edits are also fine. When the user is satisfied with the implementation, they (or the agent at their direction) run `finalize` to roll learnings back into the knowledge repo, merge the session branch to `main`, and push.

## Privacy: don't leak the knowledge repo into source

The knowledge repo is **private to the user**. Other contributors to the VS Code repo do not have access to it.

When writing code, comments, commit messages, PR descriptions, or any other artifact that lands in the public VS Code repo, **never reference**:

- The knowledge repo by name or path (e.g. `knowledge-vscode`, `$KNOWLEDGE_REPO`).
- Any doc inside it (e.g. `docs/agent-host-topology.md`, `docs/agent-host-sessions-providers.md`).
- Concepts whose only home is the knowledge repo (e.g. "agent-host topology", "well-known property names" as a knowledge-repo doc heading) phrased in a way that implies a doc the reader can look up.

Instead, inline whatever context the source code needs. If you'd otherwise want to write *"see docs/X.md for the broader story"*, replace it with a self-contained explanation in the code.

This applies the same way to `plan` and `finalize` outputs that land in the public repo (e.g. PR descriptions written from `tasks.md`). Files inside the knowledge repo itself (`plan/<session>/plan.md`, `tasks.md`, `docs/*.md`, `changes/*.md`) are private and may freely cross-reference each other.
