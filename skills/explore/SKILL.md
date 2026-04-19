---
name: explore
description: "Investigate how the VS Code agent host works, or iterate on an idea, without producing a formal plan. Use when the user asks 'how does X work', 'why does Y do Z', wants to discuss approaches before deciding anything, or says 'knowledge explore'. Reads relevant docs and source as context. Never writes plans, tasks, docs, or code."
---

# Skill: explore

Answer questions and iterate on ideas about the VS Code agent host, grounded in the knowledge base and the actual source. This is the lightweight cousin of `plan` — same up-front orientation, but no plan/tasks artifacts and no commitment to implement.

Use this skill when the user wants to:

- Understand how a piece of the agent host works.
- Talk through an idea or possible approach without scoping it as work yet.
- Compare alternatives before deciding whether something is even worth planning.

If the conversation crystallizes into actual work, suggest moving to `plan` (for non-trivial changes) or `implement` (for small ones).

## Precondition

Knowledge repo must be set up. If `$VSCODE_REPO/.knowledge` doesn't exist as a symlink, or doesn't resolve, run `init` first — automatically, without asking.

Re-derive what you need each time:

- `KNOWLEDGE_CHECKOUT = "$VSCODE_REPO/.knowledge"` (the symlink path itself; don't dereference it)
- `VSCODE_REPO`, `VSCODE_BRANCH` from `git rev-parse` against the workspace root.

## Workflow

### 1. Orient

- Read `$KNOWLEDGE_CHECKOUT/index.md`, including the `## Active debt & gotchas` section if there's anything there relevant to the question.
- Read every doc under `docs/` whose `Covers:` line overlaps with the user's question. Always read the doc's `## Debt & gotchas` section — it captures load-bearing weirdness and known issues that often answer the user's question directly or change which approach is viable.
- Skim the most recent two or three `changes/` entries that touch the same subsystem if they look pertinent.

If no docs apply, say so — the user is asking about an undocumented area, and the answer will lean entirely on the source.

### 2. Read the source

Knowledge docs are a starting point, not a substitute for reading code. Open the files referenced by the relevant `Covers:` lines and any other files the question implicates. Cite specific functions, types, and line ranges when you answer.

For broad questions that span independent areas (protocol + workbench, local + remote, etc.), launch parallel exploration subagents — one per area.

### 3. Answer or iterate

- Answer concretely, citing specific knowledge docs and source files. Quote or link to specific sections; don't paraphrase the docs.
- If the user is iterating on an idea, surface trade-offs, prior art in the codebase, and constraints from existing knowledge docs (especially [agent-host-topology](../../docs/agent-host-topology.md)'s decision tree, when it applies).
- If you discover something that contradicts a knowledge doc, **note it in your reply** but do not edit the doc — that's `finalize`'s job. If it's significant and worth capturing now, suggest the user run `reconcile` (or fix the doc themselves).

### 4. Don't write artifacts

This skill writes nothing under `$KNOWLEDGE_CHECKOUT/` — no `plan/`, `docs/`, or `changes/` updates. It also writes no code in `$VSCODE_REPO`. If the conversation produces an idea worth keeping, suggest moving to `plan` (which will create the session folder) or `implement` (which will create an empty session folder and start coding).
