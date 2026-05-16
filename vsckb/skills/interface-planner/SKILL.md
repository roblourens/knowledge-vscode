---
name: interface-planner
description: "Strongly prefer this skill for ANY Agent Host / agent host / AHP / Agent Host Protocol refactor, API-shape, interface-shape, state-shape, or protocol-shape planning request where a TypeScript signature diff would clarify the design. Use when asked to redesign Agent Host interfaces, compare current vs proposed APIs, plan a refactor, or create an interface-level implementation plan. Extracts current TypeScript interfaces into .d.ts snapshots and writes outputs under $KNOWLEDGE_REPO/plan/<session>/."
argument-hint: "What refactor or interface/API change should be planned?"
---

# Interface Planner

Use this skill to plan code changes by working with TypeScript declaration snapshots: `.d.ts` files that show only public interfaces, types, and class signatures, without implementation bodies. Like the `plan` skill, this skill never edits VS Code source files. The only files it writes are under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`.

The workflow produces two files:

- `_plan_current.d.ts`: the current state, extracted from real source files
- `_plan_proposed.d.ts`: the proposed new state after the planned changes

The final output is a side-by-side diff between these two files so the user can review the structural impact of the plan at a glance.

## Critical Diff Rule

These two files are presented as a diff. The user reads the diff to understand what changed. Every line that differs between the two files will be highlighted as a change.

- Any line that should appear unchanged must be byte-for-byte identical in both files: same text, same whitespace, no added or removed comments.
- Never add comments, annotations, or explanatory text to unchanged lines in the proposed file. That creates a false diff and makes the user think something changed when it did not.
- Only lines that actually represent a design change should differ between the two files.
- If an unchanged interface or type is not important to understanding the plan, remove it from both files to keep the diff focused.

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

## Output Location

Plan files go under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`. The `SESSION_SLUG` uses the same convention as the `plan` skill: `YYYY-MM-DD-<short-description>`. If the path already exists from another session, append `-2`, `-3`, etc.

Example:

```text
$KNOWLEDGE_REPO/plan/2026-03-28-refactor-chat-service/
```

Create or checkout the knowledge branch `knowledge/$SESSION_SLUG`, then create the session folder at the start of Phase 2, before writing any files:

```bash
mkdir -p "$KNOWLEDGE_REPO/plan/$SESSION_SLUG"
```

If a normal `plan.md` and `tasks.md` already exist for the same session, keep the interface snapshots in that same session folder. If this skill is being used standalone, the folder may contain only the interface planner files.

While running, this skill may **only** create or modify files under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`. Do not touch `docs/`, `changes/`, `index.md`, or other sessions' plan folders.

## Workflow

### Phase 1: Understand the Request

1. Read the user's request carefully. Identify which features, modules, or code areas are involved.
2. Ask clarifying questions only when the scope is genuinely ambiguous. Do not ask about details that can be discovered by reading code.

### Phase 2: Explore and Extract Current Interfaces

1. Pick `SESSION_SLUG = YYYY-MM-DD-<short-description>` and create `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/`.
2. Read `$KNOWLEDGE_REPO/index.md` and `$KNOWLEDGE_REPO/docs/design-principles.md` so the proposed interface shape follows the Agent Host design values before you extract signatures.
3. Search the codebase to identify the relevant source files: interfaces, types, classes, services, and consumers affected by the change.
4. Read those files. Focus on the public API surface: exported interfaces, type aliases, class signatures, public/protected methods and properties, enums, and important constants.
5. Follow the import graph one level out. If the interfaces being changed are consumed by or extended from other interfaces, include those too so the user can see ripple effects.
6. Write `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_current.d.ts`. This file should contain:
   - An `/* eslint-disable */` comment at the top.
   - A header comment with the date and the files it was extracted from.
   - All relevant interfaces, types, class signatures, and enums.
   - Source file annotations as comments, for example `// from src/vs/platform/chat/common/chatService.ts`.
   - Method signatures with parameter names and types, but no implementation bodies.
   - Only portions relevant to the planned change. Do not dump the entire codebase.
   - Organization by source file or logical grouping, whichever reads better.

Extraction rules:

- For classes, include only public and protected members. Omit private members unless they are essential to understanding the design.
- For interfaces, include all members.
- For methods, include the full signature and replace bodies with `;`.
- For properties, include type annotations.
- Preserve JSDoc comments that describe contracts or invariants. Omit routine comments.
- Include `extends` and `implements` clauses because they show the type hierarchy.
- Include all necessary `import` statements so every referenced type is imported. Use `import type` where the dependency is type-only. The file should have no unresolved type references.
- If a type is small and only used within the extracted interfaces, inline it or include it. Do not leave dangling references.

### Phase 3: Propose Changes Iteratively

1. Copy `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_current.d.ts` to `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_proposed.d.ts`.
2. Edit `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_proposed.d.ts` to reflect the proposed design. Typical edits include:
   - Adding new interfaces or types.
   - Adding, removing, or renaming methods on existing interfaces.
   - Splitting an interface into two.
   - Merging interfaces.
   - Changing type hierarchies with `extends` or `implements`.
   - Changing method signatures, parameters, or return types.
   - Moving members between interfaces.
3. Put all annotations on their own line above the declaration they describe. Never put an annotation inline on the same line as a declaration.

Good:

```ts
// CHANGED: now returns a Promise instead of void
doSomething(input: string): Promise<void>;

// CHANGED: type narrowed from string | undefined to string
readonly name: string;
```

Bad:

```ts
doSomething(input: string): Promise<void>; // CHANGED: now returns a Promise instead of void
readonly name: string; // CHANGED: type narrowed
```

4. Use `// CHANGED:`, `// NEW:`, `// REMOVED:`, or `// MOVED:` prefixes as appropriate.
5. Do not add comments like `// UNCHANGED` or `// same as before` on lines that have not changed. Do not touch unchanged lines in any way: no reformatting, no added comments, no reordering. The diff must only highlight actual design changes.

### Phase 3 Self-Review Loop

After writing the first draft of `_plan_proposed.d.ts`, stop and re-read both files. Ask:

- Does this proposed shape actually solve the user's problem?
- Are there simpler alternatives that have not been considered?
- Is this over-engineered by adding abstractions that are not needed yet?
- Is this under-engineered by leaving design debt that will immediately bite?
- Do the interfaces have clear single responsibilities?
- Are there awkward dependencies or circular references?
- Would the user look at this diff and immediately object to something?

If there are issues, edit `_plan_proposed.d.ts` again. If the change touches more surface area than initially extracted, add that surface area to `_plan_current.d.ts` and keep matching unchanged lines identical in `_plan_proposed.d.ts`.

Iterate up to three times. If the design is still uncertain after three rounds, present the best version and call out the uncertainty clearly; user feedback is more valuable than polishing in isolation forever.

### Phase 4: Present the Diff

1. Open the diff between the two files:

```bash
code-insiders -r --diff "$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_current.d.ts" "$KNOWLEDGE_REPO/plan/$SESSION_SLUG/_plan_proposed.d.ts"
```

The `-r` flag opens it in the current window.

2. Write a brief summary of the key changes:
   - What is new.
   - What is removed.
   - What is restructured.
   - Any tradeoffs or open questions.
3. Wait for user feedback. Do not proceed to implementation until the user approves.

### Phase 5: Iterate on Feedback

If the user provides feedback:

1. Edit `_plan_proposed.d.ts` to address it.
2. Update `_plan_current.d.ts` too if the user points out relevant existing interfaces were missed.
3. Re-open the diff view.
4. Repeat until the user approves.

### Phase 6: Hand Off to Implementation

Once approved, `_plan_proposed.d.ts` serves as the implementation spec. Either proceed to implement the changes if the user asks, or leave the files for the user or another agent/mode.

Do not delete the plan files. They serve as an archive under `$KNOWLEDGE_REPO/plan/$SESSION_SLUG/` until `finalize` cleans up the session folder.

## Constraints

- Never edit files under `$VSCODE_REPO`. Planning only.
- Never edit anything in `$KNOWLEDGE_REPO` outside `plan/$SESSION_SLUG/`. Doc updates and history entries happen at `finalize`.
- Never commit. Commits happen at `finalize`.

## Guidelines

- Scope aggressively. Only include interfaces relevant to the change. A 50-line plan file is better than a 500-line one.
- Preserve real names. Use the actual interface and method names from the codebase. Do not rename things in the snapshot unless renaming is part of the plan.
- Show the dependency web. When changing an interface, show interfaces that depend on it; this is the main value over reading raw source files.
- Do not invent implementation details. The `.d.ts` shows shapes, not implementation. Do not add private helper methods or internal state unless it is architecturally significant.
- Keep comments minimal. `// CHANGED:` and `// NEW:` annotations are for orientation, not paragraphs.
- Use valid TypeScript declaration syntax. The files should be valid `.d.ts` syntax so the user gets syntax highlighting and basic checking.
