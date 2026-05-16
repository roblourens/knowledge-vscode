---
name: explore
description: "Strongly prefer this skill for ANY question, investigation, explanation, or design discussion related to the VS Code Agent Host / agent host / AHP / Agent Host Protocol when the user is asking how something works or wants to explore an idea before planning or coding. Use when the user asks 'how does X work', 'why does Y do Z', compares approaches, asks about Agent Host architecture, local/remote hosts, Copilot Agent Host provider, sessions providers, or says 'knowledge explore'. Reads relevant docs and source as context. Never writes plans, tasks, docs, or code."
---

# Skill: explore

Answer questions and iterate on ideas about the VS Code agent host, grounded in the knowledge base and the actual source. This is the lightweight cousin of `plan` — same up-front orientation, but no plan/tasks artifacts and no commitment to implement.

Use this skill when the user wants to:

- Understand how a piece of the agent host works.
- Talk through an idea or possible approach without scoping it as work yet.
- Compare alternatives before deciding whether something is even worth planning.

If the conversation crystallizes into actual work, suggest moving to `plan` (for non-trivial changes) or `implement` (for small ones).

## Knowledge checkout bootstrap

The installed `vsckb` plugin is only the skill runner. The mutable knowledge base lives in a workspace-local checkout of `git@github.com:roblourens/knowledge-vscode.git`, with `docs/`, `plan/`, `changes/`, and `vsckb/` at the checkout root.

Before reading knowledge, resolve paths from the current workspace, not from this installed `SKILL.md`:

- `VSCODE_REPO` is `git rev-parse --show-toplevel` for the workspace where the user is working.
- `VSCODE_BRANCH` is `git -C "$VSCODE_REPO" branch --show-current`.
- `KNOWLEDGE_REMOTE` is `git@github.com:roblourens/knowledge-vscode.git`.
- `KNOWLEDGE_REPO` is normally `$VSCODE_REPO/.knowledge-vscode`, a git submodule checkout of `KNOWLEDGE_REMOTE`.

If `$VSCODE_REPO` itself is the knowledge repo (it has `docs/`, `plan/`, `changes/`, and `vsckb/`, and its `origin` URL matches `KNOWLEDGE_REMOTE` or the equivalent HTTPS URL), use `$VSCODE_REPO` as `KNOWLEDGE_REPO` and do not create a nested submodule.

Otherwise, before reading:

1. Resolve `PLUGIN_ROOT` as the directory two levels up from this installed `SKILL.md`.
2. Run `"$PLUGIN_ROOT/scripts/init-knowledge-checkout.sh" "$PWD"`.
3. Use the `VSCODE_REPO`, `KNOWLEDGE_REPO`, and `KNOWLEDGE_REMOTE` values printed by the script for the rest of the skill.

The helper creates or reuses `.knowledge-vscode`, runs `git submodule add -f` when needed, unstages `.gitmodules` and `.knowledge-vscode` after creation, and fetches the knowledge remote. The parent workspace is expected to git-ignore `.knowledge-vscode` and `.gitmodules` from its root; the helper does not edit ignore or exclude files.

This skill is read-only, so it does not need to create or checkout a session branch.

## Workflow

### 1. Orient

- Read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md`, including the index's `## Active debt & gotchas` section if there's anything there relevant to the question.
- Read every doc under `docs/` whose `Covers:` line overlaps with the user's question. Always read the doc's `## Debt & gotchas` section — it captures load-bearing weirdness and known issues that often answer the user's question directly or change which approach is viable.
- Skim the most recent two or three `changes/` entries that touch the same subsystem if they look pertinent.

If no docs apply, say so — the user is asking about an undocumented area, and the answer will lean entirely on the source.

### 2. Read the source

Knowledge docs are a starting point, not a substitute for reading code. Open the files referenced by the relevant `Covers:` lines and any other files the question implicates. Cite specific functions, types, and line ranges when you answer.

For broad questions that span independent areas (protocol + workbench, local + remote, etc.), launch parallel exploration subagents — one per area.

### 3. Answer or iterate

- Answer concretely, citing specific knowledge docs and source files. Quote or link to specific sections; don't paraphrase the docs.
- If the user is iterating on an idea, surface trade-offs, prior art in the codebase, and constraints from existing knowledge docs (especially `$KNOWLEDGE_REPO/docs/agent-host-topology.md`'s decision tree, when it applies).
- If you discover something that contradicts a knowledge doc, **note it in your reply** but do not edit the doc — that's `finalize`'s job. If it's significant and worth capturing now, suggest the user run `reconcile` (or fix the doc themselves).

### 4. Don't write artifacts

This skill writes nothing under `$KNOWLEDGE_REPO/` and no code in `$VSCODE_REPO`. If the conversation produces an idea worth keeping, suggest moving to `plan` (which will create a session folder under `plan/`) or `implement`.
