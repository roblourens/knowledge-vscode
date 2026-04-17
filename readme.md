# Agent Host Knowledge System

## Overview

This system maintains a personal knowledge base about the VS Code agent host subsystem, stored in a separate Git repo and linked into VS Code worktrees via symlinks. It is designed for one developer working with AI coding agents across multiple concurrent sessions on a large, multi-contributor codebase.

The knowledge repo is not checked into the VS Code repo. It lives independently, is versioned with Git, and is made available to coding agents by symlinking it into each VS Code worktree as `.knowledge/`. The symlink target and `.knowledge/` path are added to the VS Code repo's `.git/info/exclude` so they never appear in upstream commits.

The system has two parts: a **knowledge repo** containing docs, change logs, and task guidance, and a set of **Claude Code skills** that manage the lifecycle of linking, planning, implementing, documenting, and validating.

---

## Knowledge Repo Structure

The repo is called `vscode-knowledge` (or similar) and lives outside the VS Code repo. Its structure:

```
vscode-knowledge/
├── index.md
├── docs/
│   ├── agent-session-lifecycle.md
│   ├── state-sync-protocol.md
│   ├── chat-participants.md
│   └── ...
├── tasks/
│   ├── updating-the-protocol.md
│   ├── test-strategies.md
│   ├── interactive-verification.md
│   └── ...
├── changes/
│   ├── 2026-04-15-session-reconnect/
│   │   └── summary.md
│   ├── 2026-04-10-agent-plan-elicitation/
│   │   └── summary.md
│   └── ...
└── plan/
    └── (ephemeral, per-session planning artifacts)
```

### `index.md`

The top-level entry point. Provides general context about the agent host subsystem: what it is, where it lives in the VS Code codebase, the major architectural layers, and a brief description of each doc and task file with links. An agent starting a session should read this file first to orient itself.

### `docs/`

Each file covers a component or concern within the agent host. Files are flat (not nested) and named descriptively. Each doc:

- Describes what the component is and what it does.
- Explains how to work with it — key files, entry points, patterns to follow.
- Describes how it relates to other components, with cross-references to other docs.
- References specific files, classes, and functions in the VS Code repo by path. These references are what the `drift` skill validates.
- Ends with a **changelog section**: a reverse-chronological list of entries, each with a date, Git SHA, and short description of what changed in the component or in this doc's understanding of it.

The changelog SHAs reference whatever commit was HEAD on the working branch at the time the entry was written. These don't need to be updated later when the PR merges to main — they serve as approximate anchors for "around when did this understanding change," not precise audit markers.

Docs describe how things *are* and *why*, not how they *should be*. They are descriptive, not prescriptive. This makes them more durable than formal specs — rationale and architecture descriptions change less frequently than behavioral requirements.

### `tasks/`

Reusable guidance for recurring work patterns. These are reference docs, not executable scripts. They cover things like:

- How to make changes that span the agent protocol repo and the VS Code repo (coordination workflow, which repo to change first, how to test across boundaries).
- What types of tests are available (unit, integration, smoke, etc.), when to add each kind, and where they live.
- How to verify agent host functionality interactively (what to launch, how to connect, what to look for).

These are indexed in `index.md` alongside the component docs. They differ from docs in that they describe *how to do work* rather than *how things work*. An agent can reference them during planning and implementation.

### `changes/`

A log of completed work. One subfolder per significant conversation or feature, named with a date prefix and short description. Each contains a `summary.md` that records:

- What was done (the change, the feature, the bug fix).
- Key decisions made and why.
- What was learned that might be relevant later.
- Links to PRs if applicable.

This is a historical record, distinct from `docs/`. Docs describe the current state of the world and get updated as things change. Changes are append-only history — they capture the *narrative* of how the system evolved. They're useful for answering "why did we do it this way?" months later, and for providing an agent with recent change context when working in a related area.

### `plan/`

Ephemeral planning artifacts for the current session. Task lists, implementation notes, spec diffs. These are written by the `plan` skill and consumed by the `implement` skill. They can be committed to the knowledge repo on a branch for the session, but they're working documents, not permanent artifacts. When a session is finalized, the meaningful parts are distilled into a `changes/` entry and possibly updates to `docs/`.

---

## Skills

These are Claude Code custom slash commands installed in the user's global Claude Code configuration (not in the VS Code repo). They operate on the `.knowledge/` directory within the current VS Code worktree.

### `/knowledge-init`

**Purpose:** Set up the knowledge repo link for the current worktree.

**Behavior:**

1. Check if `.knowledge/` already exists in the current working directory. If so, confirm it's a valid symlink and exit.
2. Determine the path to the `vscode-knowledge` repo (configurable, defaults to a sibling directory of the VS Code repo).
3. Determine a branch name for this session. Use the current VS Code branch name as a basis (e.g., if the VS Code worktree is on branch `feature/agent-reconnect`, create or checkout a knowledge branch called `feature/agent-reconnect`). If the branch already exists in the knowledge repo, check it out; otherwise, create it from `main`.
4. Create a worktree of the knowledge repo at a conventional location (e.g., alongside the VS Code worktree or in a `.worktrees/` directory within the knowledge repo).
5. Symlink that worktree into the VS Code worktree as `.knowledge/`.
6. Verify that `.knowledge` is excluded from Git tracking (check `.git/info/exclude` or `.gitignore`; add it if missing).
7. Read `.knowledge/index.md` and provide a brief summary of available context to the agent.

**Concurrency:** Multiple VS Code worktrees can each have their own knowledge worktree and symlink. The knowledge branches provide isolation. Since knowledge docs change less frequently than code, merge conflicts will be rare and easy to resolve (they're just prose).

### `/knowledge-plan`

**Purpose:** Plan a change by reading relevant knowledge context and producing a task list.

**Precondition:** `.knowledge/` must exist. If it doesn't, instruct the user to run `/knowledge-init`.

**Behavior:**

1. Read `index.md` to orient.
2. Based on the user's prompt or the current task context, identify which docs and task guides are relevant. Read them.
3. Produce a plan in `.knowledge/plan/`:
   - `plan.md` — the approach, referencing relevant knowledge docs and task guides.
   - `tasks.md` — ordered task list with dependencies.
4. If the plan would change behavior described in existing docs, note which docs will need updating and what the expected changes are. Don't edit the docs yet — that happens at finalize.
5. Present the plan to the user for review.

### `/knowledge-implement`

**Purpose:** Implement a planned change, or implement directly from a prompt.

**Precondition:** `.knowledge/` must exist. If it doesn't, instruct the user to run `/knowledge-init`.

**Behavior:**

1. If a plan exists in `.knowledge/plan/`, read it and work through the tasks.
2. If no plan exists, work from the user's prompt directly, but still read relevant knowledge docs for context before starting.
3. Reference task guides (e.g., test strategies, interactive verification) as appropriate during implementation.
4. Implement in the VS Code worktree as normal — edit files, run tests, iterate.

This skill is deliberately lightweight. It's the normal agent coding workflow, augmented by reading knowledge context first.

### `/knowledge-finalize`

**Purpose:** Capture what was learned in this session back into the knowledge repo.

**Precondition:** `.knowledge/` must exist.

**Behavior:**

1. Review the conversation history for the current session. Identify:
   - New understanding about components that should be added to or updated in existing docs.
   - Context that was missing from the knowledge base but turned out to be relevant — things the agent had to discover by reading code that should be documented for future sessions.
   - Decisions that were made and their rationale.
2. Update relevant files in `.knowledge/docs/`:
   - Add or revise descriptions of components.
   - Update cross-references if relationships changed.
   - Append a changelog entry with today's date, the current HEAD SHA, and a short description.
3. Create a new entry in `.knowledge/changes/` with a summary of the session: what was done, decisions made, and anything noteworthy.
4. Update `.knowledge/index.md` if new docs were created.
5. Clean up `.knowledge/plan/` — remove or archive ephemeral planning artifacts.
6. Commit the knowledge repo changes on the current branch.
7. Merge the knowledge branch back to `main` (or leave it for the user to merge, depending on preference).
8. If the current VS Code directory is a worktree (not the main checkout), remove the symlink and clean up the knowledge worktree. If it's the main checkout, leave the symlink in place.

### `/knowledge-drift`

**Purpose:** Check whether the knowledge docs are still accurate against the current state of the VS Code codebase.

**Precondition:** `.knowledge/` must exist.

**Behavior:**

1. Parse all files in `.knowledge/docs/` for references to VS Code repo paths, file names, class names, function names, and other identifiable code symbols.
2. Check whether those references still exist in the VS Code repo. Flag any that point to files or symbols that have been deleted, renamed, or moved.
3. For each doc, read the referenced code and compare it to the doc's description. Flag significant discrepancies — e.g., a doc describes a class as having certain responsibilities but the class has been substantially refactored.
4. Produce a drift report: which docs are still valid, which have stale references, which may have semantic drift.
5. Optionally, offer to update the docs in place with corrected references and descriptions, appending a changelog entry noting the drift correction.

The mechanical reference check (step 2) should run first and is cheap. The semantic comparison (step 3) requires reading code and is more expensive — it can be scoped to only docs that have stale references, or run on all docs if the user requests a full audit.

---

## Workflow

A typical session:

1. Create a VS Code worktree for a feature branch.
2. Run `/knowledge-init` to link the knowledge repo.
3. Run `/knowledge-plan` to plan the work with full context, or jump straight to `/knowledge-implement` for smaller changes.
4. Do the work. Agent reads relevant docs and task guides as needed.
5. Run `/knowledge-finalize` to capture what was learned and clean up.

Periodically (e.g., weekly, or after a batch of teammates' PRs land):

6. Run `/knowledge-drift` on the main checkout to find and fix stale docs.

---

## Design Decisions

**Why a separate repo, not gitignored files in the VS Code repo:** Gitignored files aren't version-controlled. The knowledge base needs its own history, branching, and the ability to be shared later without touching the VS Code repo.

**Why symlinks, not a VS Code multi-root workspace:** The agent needs to see `.knowledge/` as part of the working tree to read and write it naturally. A symlink achieves this. A multi-root workspace is a UI convenience for the human (seeing diffs in both repos) but doesn't help the agent. Both can be used together — the symlink for the agent, a `.code-workspace` file for the human if desired.

**Why worktree-per-session for the knowledge repo:** To support multiple concurrent agent sessions without conflicts. Each session gets its own knowledge branch and worktree, paired with its VS Code worktree. Since knowledge docs change infrequently compared to code, most sessions won't touch them, and the branches will merge trivially.

**Why flat `docs/` instead of mirroring the VS Code repo's directory structure:** The VS Code repo is deep and complex. Mirroring it would create empty directories, hard-to-find files, and maintenance overhead. Flat files with descriptive names and cross-references in `index.md` are easier to browse and maintain. Docs reference the VS Code paths they cover, which is sufficient for navigation and drift detection.

**Why `changes/` is separate from `docs/`:** Docs are mutable descriptions of the current state. Changes are an immutable log of what happened. They serve different purposes: docs answer "how does this work?" and changes answer "why is it this way?" and "what was tried?" Both are useful, and conflating them would make docs bloated with historical narrative.

**Why changelog SHAs reference the working branch, not the merge commit:** Recording the merge-to-main SHA would require coming back to the knowledge repo after the PR merges, which adds friction and will be forgotten. The working branch SHA is good enough — it anchors the entry in time and can be correlated with a PR if needed. Precision isn't worth the workflow cost.