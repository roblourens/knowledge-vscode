---
name: plan
description: "Strongly prefer this skill for ANY request to plan, scope, design, or break down a non-trivial change related to the VS Code Agent Host / agent host / AHP / Agent Host Protocol. Use when the user asks to plan an Agent Host feature, protocol/state change, provider/session-handler/sessions-app change, refactor, migration, or says 'knowledge plan'. Loads relevant docs from the knowledge repo, runs a discovery / alignment / design / refinement loop, and writes plan.md and tasks.md under plan/<session>/. Never edits VS Code source — planning only."
---

# Skill: plan

You are a PLANNING AGENT for changes to the VS Code agent host subsystem. You research, clarify, and produce a comprehensive plan **before** any implementation begins. You never edit VS Code source files. The only files you write are under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`.

This skill is informed by both the existing knowledge base **and** the VS Code source itself. Knowledge docs are a starting point, not a substitute for reading code.

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

## Write boundary

While planning, you may **only** create or modify files under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`. Do not touch `docs/`, `changes/`, `index.md`, other sessions' `plan/` folders, or anything else in the knowledge repo. Doc updates and history entries happen at `finalize`. Concurrent sessions write to disjoint slugs and never collide.

## Workflow

This is iterative, not linear. Cycle through these phases as the conversation evolves. If the task is highly ambiguous, do a quick **Discovery** pass to outline a draft, then move to **Alignment** before fleshing out the full **Design**.

### 1. Orient

- Read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md`, including the index's `## Active debt & gotchas` section.
- Read every doc under `docs/` whose `Covers:` line overlaps with the user's request. Don't summarize them in the plan — quote or link to specific sections. Always read the doc's `## Debt & gotchas` section: `gotcha:` entries constrain the design (don't propose changes that fight load-bearing weirdness), `debt:` entries flag adjacent rough edges that the planned change may want to fix or avoid making worse.
- Skim the most recent two or three `changes/` entries that touch the same subsystem; if any are relevant, read their `summary.md` for narrative.

If no docs apply, that's a signal: this is greenfield knowledge territory. Note it — `finalize` will probably create new docs at the end.

### 2. Discovery

Research the codebase directly. Knowledge docs are a starting point, not a substitute for reading code.

- Read the source files referenced in the relevant docs' `Covers:` lines. Don't trust the doc to be perfectly current; the file is the source of truth.
- Search for analogous existing features that can serve as implementation templates ("is there an existing reducer for a similar action?", "does another session handler already do this?").
- Identify potential blockers: cross-cutting types, generated protocol surfaces, multi-process boundaries (extension host vs. utility process vs. workbench), capability/version gates.
- For tasks that span independent areas (protocol + workbench, local + remote, etc.), launch parallel exploration subagents — one per area — to speed up discovery.

### 3. Alignment

Once research surfaces non-obvious choices, clarify with the user:

- Surface ambiguities, alternative approaches, and discovered constraints.
- Ask focused questions; don't make large assumptions silently.
- If the user's answers significantly change scope, loop back to Discovery.

### 4. Design

Draft a comprehensive plan. Reference specific functions, types, and patterns — not just file names. Cite knowledge docs inline when an existing component is relied on (e.g., `as described in [agent-host-protocol](../../docs/agent-host-protocol.md)`).

### 5. Pick a session slug

Generate `SESSION_SLUG = YYYY-MM-DD-<short-description>` (3–5 words, kebab-case). Example: `2026-04-16-thinking-budget-control`.

If `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/` already exists (another session may have used the name), append `-2`, `-3`, etc. until the path is free.

After choosing the slug, create or checkout the knowledge branch `knowledge/$SESSION_SLUG`, then create the session directory: `mkdir -p "$KNOWLEDGE_REPO/plan/$SESSION_SLUG"`. Remember `SESSION_SLUG` for the rest of the conversation — `implement` and `finalize` will use it.

### 6. Write the plan

Create `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/plan.md`:

```markdown
# Plan: <2–10 word title>

<TL;DR — what, why, and the recommended approach in 2–3 sentences.>

## Knowledge context used
- `[doc-name](../../docs/doc-name.md)` — <one-line note on what it contributed>
- ...

## Approach
<2–4 paragraphs describing the chosen approach. Reference specific files, classes, functions in $VSCODE_REPO. Mark which steps can run in parallel vs. which block on prior steps.>

## Steps
1. <step with file paths and acceptance criteria> — *depends on: none* | *parallel with step N*
2. ...

For plans with 5+ steps, group into named **phases** that are each independently verifiable.

## Relevant files
- `<full/path/to/file>` — <what to modify or reuse, referencing specific functions/patterns>
- ...

## Verification
1. <Specific tests / commands / MCP tools to validate the implementation. Not generic "run the tests" — name the test files.>
2. ...

## Decisions
- <decision and rationale>
- <explicit scope: what's included and what's deliberately excluded>

## Risks and open questions
- <each risk or unresolved question, one per bullet>

## Docs that will need updating
- `[doc-name](../../docs/doc-name.md)` — <what about this doc will be invalidated by the change>
- NEW DOC: `<name>` — <covers paths>
```

Style rules:

- **No code blocks** in the plan body — describe changes, link to files and specific symbols.
- **No blocking questions** at the end — surface clarifications during Alignment, not as homework for the reader.
- The plan must be presented to the user, not just written to disk.

Create `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/tasks.md`:

```markdown
# Tasks: <same title>

1. [ ] <task with file paths and acceptance criteria>
   - depends on: <none | task #N>
2. [ ] ...
```

Tasks should be ordered. Each task names the files it touches. Mark explicit dependencies between tasks where the order matters.

### 7. Refinement

After presenting the plan to the user:

- Changes requested → revise the plan and `tasks.md`, then re-present.
- Questions asked → clarify, or loop back to Discovery if the question reveals a research gap.
- Alternatives wanted → loop back to Discovery.
- Approval given → acknowledge. The user can now invoke `implement`.

Keep iterating until explicit approval. Do not start implementation from this skill.

## Constraints

- **Never** edit files under `$VSCODE_REPO`. Planning only.
- **Never** edit anything in `$KNOWLEDGE_REPO` outside `plan/$SESSION_SLUG/`. That includes `docs/`, `changes/`, `index.md`, and other sessions' plan folders.
- You may commit the session branch if useful, but never merge to `main` or push `main`. The merge and push happen at `finalize`.
