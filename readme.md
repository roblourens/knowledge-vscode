# Agent Host Knowledge System

## Overview

This system maintains a personal knowledge base about the VS Code agent host subsystem, stored in a separate Git repo and accessed by AI coding agents via a set of namespaced skills. It is designed for one developer working with AI coding agents across multiple concurrent sessions on a large, multi-contributor codebase.

This repo *is* the knowledge repo. It is not checked into the VS Code repo and lives independently. Coding agents access it through skills shipped as a VS Code agent plugin (this same repo). Each skill resolves the knowledge repo path from its own `SKILL.md` location — there's no setting, no symlink, no per-session worktree.

The system has two parts: a **knowledge repo** (this repo) containing docs, change logs, and task guidance, and the **`vsckb` VS Code agent plugin** (under `vsckb/`, in the same Team Kit-style agent plugin format used by `vscode-team-kit`) that ships a set of skills (`explore`, `plan`, `implement`, `finalize`, `reconcile`, `interface-planner`, `help`) which manage the lifecycle of planning, implementing, documenting, and validating. Installing the plugin registers the skills under the `vsckb` namespace in VS Code (e.g. `vsckb:plan`, `vsckb:implement`).

---

## Knowledge Repo Structure

The knowledge repo is this repo. Its structure:

```
knowledge-vscode/
├── index.md
├── marketplace.json
├── readme.md
├── docs/
│   ├── agent-host-protocol.md
│   ├── agent-host-session-handler.md
│   └── ...
├── vsckb/
│   ├── .plugin/
│   │   └── plugin.json
│   └── skills/
│       └── ...
├── changes/
│   ├── 2026-04-15-session-reconnect/
│   │   └── summary.md
│   └── ...
└── plan/
    ├── 2026-04-15-session-reconnect/
    │   ├── plan.md
    │   └── tasks.md
    └── ...
```

### `index.md`

The top-level entry point. Provides general context about the agent host subsystem: what it is, where it lives in the VS Code codebase, the major architectural layers, and a brief description of each doc and task file with links. An agent starting a session should read this file first to orient itself.

**Retrieval:** For now, retrieval is intentionally simple — `index.md` plus keyword/search through `docs/` is the whole story. Each doc entry in `index.md` should include a one-line description rich enough that keyword search finds it, plus a `Covers:` listing of the VS Code paths it concerns. If the knowledge base grows large enough that this stops being enough, we can add tags, embeddings, or a smarter retrieval skill later.

### `docs/`

Each file covers **one component or concern** within the agent host. "Component" is deliberately loose — it can be:

- a single file,
- a single class within a file,
- a folder or coherent set of files that work together,
- or a cross-cutting concern (a protocol, a lifecycle, a pattern).

The rule of thumb: a doc should have a small, declarable set of paths in the VS Code repo that it is *primarily* concerned with. If you can't list them in a sentence or two, the doc is probably trying to cover too much and should be split.

Each doc:

- Declares the VS Code paths it primarily covers (in a frontmatter block or a `Covers:` line near the top), so `reconcile` knows which Git history to diff against.
- Describes what the component is and what it does.
- Explains how to work with it — key files, entry points, patterns to follow.
- Describes how it relates to other components, with cross-references to other docs.
- References specific files, classes, and functions in the VS Code repo by path. These references are what `reconcile` validates.
- Has a **`## Debt & gotchas` section** between the body and the changelog, capturing things to revisit and load-bearing weirdness to preserve. Two entry types:
  - **`gotcha`** — something is the way it is on purpose; if you touch it, do Y. Presumed permanent.
  - **`debt`** — something looks wrong, could be cleaned up, or needs revisiting. Resolved when fixed.
  Each entry is one bullet line: `- **<kind>** (YYYY-MM-DD, <file:symbol>) — <description>`.
- Ends with a **changelog section**: a reverse-chronological list of entries, each with a date, Git SHA, and short description of what changed in the component or in this doc's understanding of it.

**Cross-linking between docs:** Use plain Markdown links with relative paths (e.g., `[state sync protocol](./state-sync-protocol.md)`). Mention related docs inline where they're relevant rather than collecting them into a separate "See also" section. `index.md` is the only place that tries to be exhaustive about what exists.

**Every new doc starts with an initial changelog entry** — there is no doc without a baseline. The SHA used for that initial entry depends on context:

- If the doc is describing existing state in the VS Code repo, use the current HEAD of `origin/main`.
- If the doc is describing something that's part of an in-flight change, use the current HEAD of whatever branch is checked out, even if it's a feature branch.

The changelog SHAs reference whatever commit was HEAD on the working branch at the time the entry was written. They serve as approximate anchors for "around when did this understanding change" and as the baseline `reconcile` diffs against.

Docs describe how things *are* and *why*, not how they *should be*. Prescriptive how-to-work-with-this-component notes belong in the relevant doc itself — there's no separate task-guide layer.

### `changes/`

A log of completed work. One subfolder per significant conversation or feature, named with a date prefix and a short description (e.g., `2026-04-15-session-reconnect/`). Each contains a `summary.md` that records what was done, key decisions, what went wrong or was misunderstood, and what was learned. Append-only history.

### `plan/`

Ephemeral planning artifacts for the current session. Each session gets its own subfolder named `YYYY-MM-DD-short-description/`. **The session that owns the slug is the only writer for that folder.** Concurrent sessions in other VS Code windows write to disjoint slugs and never collide. When `finalize` runs, the meaningful parts are distilled into a `changes/` entry and possibly updates to `docs/`, and the session's `plan/` subfolder is removed.

---

## Skills

These skills ship as part of the `vsckb` VS Code agent plugin in this repo, in the same Team Kit-style format used by `vscode-team-kit`. The repo-level `marketplace.json` points to `./vsckb/` as the plugin root. Installing the plugin registers the skills under the `vsckb` namespace, so they show up grouped in VS Code as `vsckb:plan`, `vsckb:implement`, etc.

Each skill resolves the knowledge repo path from its own `SKILL.md` location — `KNOWLEDGE_REPO` is the directory three levels up from `vsckb/skills/<skill>/SKILL.md`. There's no init step, no setting, no symlink, no worktree.

### Write boundaries

The whole concurrency story is enforced by two simple rules:

1. **`plan` and `implement` (and `interface-planner`) only ever write to `plan/<SESSION_SLUG>/`.** Never to `docs/`, `changes/`, `index.md`, or another session's plan folder.
2. **`finalize` and `reconcile` are the only skills that write outside `plan/<slug>/`** — and they're also the only skills that commit and push. They `git pull --rebase` first, then commit and push directly to `main`. If a concurrent session pushed something they conflict with, the rebase fails and the user resolves it.

That's it. Concurrent sessions are safe because they touch disjoint slugs, and the commit step is serialized through `origin/main`.

### `explore`

**Purpose:** Answer questions about how the agent host works, or iterate on an idea, with knowledge docs and source loaded as context. Writes nothing.

**Behavior:**

1. Read `index.md` and any `docs/` whose `Covers:` overlaps with the question.
2. Read the relevant source — docs are a starting point, not a substitute for the code.
3. Answer concretely, citing specific functions, types, and source files. If iterating on an idea, surface trade-offs and prior art in the codebase.
4. Write nothing — no `plan/`, `docs/`, or `changes/` updates, and no code in `$VSCODE_REPO`. If the conversation produces an idea worth keeping, suggest moving to `plan` or `implement`.

### `plan`

**Purpose:** Plan a change by reading relevant knowledge context and producing a task list.

**Behavior:**

1. Read `index.md` to orient.
2. Identify which docs are relevant. Read them.
3. Generate a `SESSION_SLUG = YYYY-MM-DD-short-description` (suffix `-2`, `-3`... if the path already exists), and create `plan/$SESSION_SLUG/`.
4. Produce `plan.md` and `tasks.md` in that folder.
5. If the plan would change behavior described in existing docs, note which docs will need updating — but don't edit them. That happens at finalize.
6. Present the plan to the user for review.

### `implement`

**Purpose:** Implement a planned change, or implement directly from a prompt.

**Behavior:**

1. Reuse the `SESSION_SLUG` from the earlier `plan` (or pick/create one).
2. If a plan exists for this session under `plan/$SESSION_SLUG/`, read it and work through `tasks.md`.
3. If no plan exists, work from the user's prompt directly, but still read relevant knowledge docs for context before starting.
4. Implement in the VS Code worktree as normal. Keep `tasks.md` in sync as you go (check items off, note deviations, log discoveries for `finalize`).

This skill is deliberately lightweight. It's the normal agent coding workflow, augmented by reading knowledge context first.

### `finalize`

**Purpose:** Capture what was learned in this session, then commit and push it directly to `main`.

**Behavior:**

1. Verify the working tree has no other in-flight edits that don't belong to this session.
2. `git fetch origin main` and `git pull --rebase --autostash origin main`. If the rebase fails (concurrent finalize touched the same docs), stop and surface the conflict.
3. Run a retrospective on the session — what was misunderstood, what was a dead end, what should have been documented but wasn't — and map each finding to a `gotcha:`/`debt:` entry, doc body update, new doc, or `changes/` summary.
4. Update affected files in `docs/`: revise descriptions, update cross-references, update `## Debt & gotchas`, append a changelog entry with today's date and the current HEAD SHA of the VS Code working branch.
5. Create new docs if needed; update `index.md` to list them.
6. Remove the session's `plan/$SESSION_SLUG/` subfolder.
7. Write `changes/$SESSION_SLUG/summary.md` (with the mandatory **What went wrong or was misunderstood** section).
8. `git add -A && git commit -m "<title from summary>" && git push origin main`. If the push is rejected, re-run `pull --rebase` and retry once.

`finalize` is the only place that commits work for a session. There's no separate review-and-publish step — once you invoke `finalize`, the result lands on `main`. To amend, edit the knowledge repo directly and make a follow-up commit.

### `reconcile`

**Purpose:** Detect drift between the knowledge docs and the current VS Code codebase, and **update the docs in place** to match.

**Key idea:** Each doc has a baseline anchor — the most recent changelog entry's SHA (and date). Reconciliation works by looking at what has changed in the VS Code repo *since* that baseline and asking whether any of those changes touch what the doc describes. If nothing relevant changed, the doc is presumed still accurate and is not re-read in detail.

**Behavior:**

1. Pull-rebase the knowledge repo so updates land on top of any concurrent work.
2. For each doc, read `Covers:` and the latest changelog entry to get a baseline SHA.
3. Compute the set of VS Code commits between each doc's baseline SHA and `origin/main`.
4. For docs with no overlap, bump the changelog SHA in place (no body changes) — the doc is presumed current. This is what makes the next reconcile cheap.
5. For docs with overlap, drill in: read the changed code and commits, update the doc body, revisit `## Debt & gotchas`, append a changelog entry.
6. Mechanical pass for any references to deleted/renamed/moved files or symbols, regardless of baseline.
7. Commit and push the result directly to `main`.

### `interface-planner`

**Purpose:** Plan a refactor by extracting current TypeScript interfaces into a `.d.ts` snapshot, iterating on a proposed `.d.ts` shape, and opening a side-by-side diff for review. Writes only under `plan/$SESSION_SLUG/`. Doesn't commit.

### `help`

**Purpose:** Explain the plugin and the workflow to the user.

---

## Workflow

A typical session:

1. Open VS Code in the VS Code repo (or any worktree of it).
2. Start a chat session and ask the agent to plan or implement.
3. The agent uses `plan` for larger work (writes to `plan/<slug>/`), or jumps straight to `implement` for smaller changes.
4. Do the work. Agent reads relevant docs as needed.
5. Run `finalize` to capture what was learned, update the docs, write a `changes/` entry, and commit it directly to `main`.

Periodically (e.g., weekly, or after a batch of teammates' PRs land):

6. Run `reconcile` to update stale docs against the current VS Code codebase. This also commits and pushes.

---

## Design Decisions

**Why a separate repo, not gitignored files in the VS Code repo:** Gitignored files aren't version-controlled. The knowledge base needs its own history, branching, and the ability to be shared later without touching the VS Code repo.

**Why no init / worktree / symlink layer:** An earlier version of this system gave each session its own knowledge worktree on a session-named branch, exposed under `<vscode>/.knowledge/`, with a separate `land` skill that committed and merged the worktree back into `main`. That bought isolation between concurrent sessions but cost a complex init flow, broken-symlink failure modes, and an extra publish step. The simpler shape is: every session reads and writes the same checkout, but the *only* place plan/implement may write is `plan/<slug>/`, which is owned by exactly one session. `docs/` and `changes/` are only written by `finalize` and `reconcile`, both of which pull-rebase before committing. Conflicts are rare (knowledge changes infrequently) and obvious when they happen.

**Why mostly flat `docs/` instead of mirroring the VS Code repo's directory structure:** The VS Code repo is deep and complex. Mirroring it would create empty directories, hard-to-find files, and maintenance overhead, and it would also force each doc to live at one canonical location even though many docs cut across the tree. Flat files with descriptive names, declared `Covers:` paths, and cross-references in `index.md` are easier to browse and maintain.

**Why `changes/` is separate from `docs/`:** Docs are mutable descriptions of the current state. Changes are an immutable log of what happened. They serve different purposes: docs answer "how does this work?" and changes answer "why is it this way?" and "what was tried?"

**Why drift detection is driven by the VS Code Git history, not by re-reading every doc:** The naive approach — read each doc, re-read every code reference, compare — is expensive and scales badly. The Git history is the cheaper signal: if nothing in the VS Code repo has changed in the area a doc describes since that doc's baseline, the doc is presumed still accurate.

**Why debt and gotchas live per-doc instead of in a standalone debt doc:** A standalone debt doc rots quickly because nothing forces you to revisit it when the related code changes, and it duplicates context that already lives in the doc. Per-doc entries are loaded automatically whenever an agent reads the doc, and `reconcile` can validate `debt:` entries against the code in the same pass that validates the rest of the doc. Cross-cutting items get a short pointer in `index.md`.

**Why `finalize` commits straight to `main` instead of going through a review step:** The earlier two-step `finalize` + `land` flow added a manual checkpoint between writing the diff and publishing it. In practice the diff was almost always good, and the extra step mostly added latency. Committing straight to `main` keeps the loop tight; if a finalize is wrong, the user edits the repo and makes a follow-up commit.

**Why changelog SHAs reference the working branch, not the merge commit:** Recording the merge-to-main SHA would require coming back to the knowledge repo after the PR merges, which adds friction and will be forgotten. The working branch SHA is good enough — it anchors the entry in time, gives drift detection a baseline to diff against, and can be correlated with a PR if needed.
