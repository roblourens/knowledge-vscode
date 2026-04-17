# Agent Host Knowledge System

## Overview

This system maintains a personal knowledge base about the VS Code agent host subsystem, stored in a separate Git repo and accessed by AI coding agents via a set of namespaced skills. It is designed for one developer working with AI coding agents across multiple concurrent sessions on a large, multi-contributor codebase.

This repo *is* the knowledge repo. It is not checked into the VS Code repo and lives independently. Coding agents access it through skills that resolve its location from a user-managed setting (no symlinks, no entries in the VS Code worktree).

The system has two parts: a **knowledge repo** (this repo) containing docs, change logs, and task guidance, and a **VS Code agent plugin** (also in this repo, in the same Team Kit-style agent plugin format used by `vscode-team-kit`) that ships a set of `knowledge-*` skills which manage the lifecycle of locating the repo, planning, implementing, documenting, and validating. Installing the plugin registers the skills under a `knowledge-*` namespace in VS Code.

---

## Knowledge Repo Structure

The knowledge repo is this repo. Its structure:

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
    ├── 2026-04-15-session-reconnect/
    │   ├── plan.md
    │   └── tasks.md
    └── ...
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

**Every new doc starts with an initial changelog entry** — there is no doc without a baseline. The SHA used for that initial entry depends on context:

- If the doc is describing existing state in the VS Code repo, use the current HEAD of `main`.
- If the doc is describing something that's part of an in-flight change, use the current HEAD of whatever branch is checked out, even if it's a feature branch. (This case is a little TBD and may be refined later.)

The changelog SHAs reference whatever commit was HEAD on the working branch at the time the entry was written. These don't need to be updated later when the PR merges to main — they serve as approximate anchors for "around when did this understanding change" and as the baseline drift detection diffs against, not as precise audit markers.

Docs describe how things *are* and *why*, not how they *should be*. They are descriptive, not prescriptive. This makes them more durable than formal specs — rationale and architecture descriptions change less frequently than behavioral requirements.

### `tasks/`

Reusable guidance for recurring work patterns. These are reference docs, not executable scripts. They cover things like:

- How to make changes that span the agent protocol repo and the VS Code repo (coordination workflow, which repo to change first, how to test across boundaries).
- What types of tests are available (unit, integration, smoke, etc.), when to add each kind, and where they live.
- How to verify agent host functionality interactively (what to launch, how to connect, what to look for).

These are indexed in `index.md` alongside the component docs. They differ from docs in that they describe *how to do work* rather than *how things work*. An agent can reference them during planning and implementation.

### `changes/`

A log of completed work. One subfolder per significant conversation or feature, named with a date prefix and a short description of the task (e.g., `2026-04-15-session-reconnect/`). Each contains a `summary.md` that records:

- What was done (the change, the feature, the bug fix).
- Key decisions made and why.
- What was learned that might be relevant later.
- Links to PRs if applicable.

This is a historical record, distinct from `docs/`. Docs describe the current state of the world and get updated as things change. Changes are append-only history — they capture the *narrative* of how the system evolved. They're useful for answering "why did we do it this way?" months later, and for providing an agent with recent change context when working in a related area.

### `plan/`

Ephemeral planning artifacts for the current session. Task lists, implementation notes, spec diffs. Each session gets its own subfolder, named with the same `YYYY-MM-DD-short-description` convention as `changes/` so plans and the resulting change entry line up and concurrent sessions don't collide. Inside, the `plan` skill writes `plan.md` and `tasks.md`, which the `implement` skill consumes. These are working documents, not permanent artifacts. When a session is finalized, the meaningful parts are distilled into a `changes/` entry and possibly updates to `docs/`, and the session's `plan/` subfolder is cleaned up.

---

## Skills

These skills ship as part of a VS Code agent plugin in this repo, in the same Team Kit-style format used by `vscode-team-kit`. Installing the plugin registers them under a `knowledge-*` namespace so they show up grouped in VS Code. They are invoked by the agent (and by the user when they want to drive the workflow explicitly).

The skills locate the knowledge repo from a user-managed VS Code setting. The setting itself (name, scope, default) is left for the user to wire up — the skills just read it.

**Auto-init:** Any skill that needs the knowledge repo should run the `knowledge-init` logic automatically if it hasn't been set up yet for the current session. The user should never be told "run init first."

### `knowledge-init`

**Purpose:** Prepare the knowledge repo for use in the current session.

**Behavior:**

1. Resolve the path to the knowledge repo from the user-managed VS Code setting.
2. Detect whether the current VS Code checkout is a worktree (i.e., not the main checkout).
3. Determine a knowledge branch name based on the current VS Code branch (e.g., VS Code on `feature/agent-reconnect` → knowledge branch `feature/agent-reconnect`). If the branch already exists, check it out; otherwise, create it from `main`.
4. If the VS Code checkout is a worktree, create a matching worktree of the knowledge repo at a conventional location (e.g., `.worktrees/<branch>` within the knowledge repo) and use it for this session. If the VS Code checkout is the main checkout, operate on the knowledge repo's main checkout directly on the chosen branch — no worktree needed.
5. Read `index.md` from the resolved knowledge location and provide a brief summary of available context to the agent.

**Concurrency:** Multiple VS Code worktrees can each have their own knowledge worktree. The knowledge branches provide isolation. Since knowledge docs change less frequently than code, merge conflicts will be rare and easy to resolve (they're just prose).

**Concurrency:** Multiple VS Code worktrees can each have their own knowledge worktree. The knowledge branches provide isolation. Since knowledge docs change less frequently than code, merge conflicts will be rare and easy to resolve (they're just prose).

### `knowledge-plan`

**Purpose:** Plan a change by reading relevant knowledge context and producing a task list.

**Precondition:** Knowledge repo is set up. If not, run `knowledge-init` automatically before continuing.

**Behavior:**

1. Read `index.md` to orient.
2. Based on the user's prompt or the current task context, identify which docs and task guides are relevant. Read them.
3. Produce a plan in a new session subfolder under the knowledge repo's `plan/` directory, named `YYYY-MM-DD-short-description/`:
   - `plan.md` — the approach, referencing relevant knowledge docs and task guides.
   - `tasks.md` — ordered task list with dependencies.
4. If the plan would change behavior described in existing docs, note which docs will need updating and what the expected changes are. Don't edit the docs yet — that happens at finalize.
5. Present the plan to the user for review.

### `knowledge-implement`

**Purpose:** Implement a planned change, or implement directly from a prompt.

**Precondition:** Knowledge repo is set up. If not, run `knowledge-init` automatically before continuing.

**Behavior:**

1. If a plan exists for this session under the knowledge repo's `plan/` directory, read it and work through the tasks.
2. If no plan exists, work from the user's prompt directly, but still read relevant knowledge docs for context before starting.
3. Reference task guides (e.g., test strategies, interactive verification) as appropriate during implementation.
4. Implement in the VS Code worktree as normal — edit files, run tests, iterate.

This skill is deliberately lightweight. It's the normal agent coding workflow, augmented by reading knowledge context first.

### `knowledge-finalize`

**Purpose:** Capture what was learned in this session back into the knowledge repo.

**Behavior:**

Finalize does not require a knowledge worktree — it commits changes directly to the knowledge repo on the session's branch. If a worktree was created earlier by `knowledge-init` for this session, finalize uses it; otherwise it operates on the main checkout of the knowledge repo on the chosen branch.

1. Review the conversation history for the current session. Identify:
   - New understanding about components that should be added to or updated in existing docs.
   - Context that was missing from the knowledge base but turned out to be relevant — things the agent had to discover by reading code that should be documented for future sessions.
   - Decisions that were made and their rationale.
2. Update relevant files in `docs/`:
   - Add or revise descriptions of components.
   - Update cross-references if relationships changed.
   - Append a changelog entry with today's date, the current HEAD SHA (of the VS Code working branch), and a short description.
   - When creating a brand-new doc, give it an initial changelog entry as described in the `docs/` section above.
3. Create a new entry in `changes/` under a `YYYY-MM-DD-short-description/` subfolder with a `summary.md`: what was done, decisions made, and anything noteworthy.
4. Update `index.md` if new docs were created.
5. Clean up this session's subfolder under `plan/`.
6. Commit the knowledge repo changes on the current branch.
7. Merge the knowledge branch back to `main` (or leave it for the user to merge, depending on preference).
8. If a knowledge worktree was created for this session, remove it.

### `knowledge-drift`

**Purpose:** Check whether the knowledge docs are still accurate against the current state of the VS Code codebase, using the VS Code Git history as the driver — not by re-reading every doc against the code.

**Precondition:** Knowledge repo is set up. If not, run `knowledge-init` automatically before continuing.

**Key idea:** Each doc has a baseline anchor — the most recent changelog entry's SHA (and/or date) recording the last time the doc was reconciled with the code. Drift detection works by looking at what has changed in the VS Code repo *since* that baseline and asking whether any of those changes touch what the doc describes. If nothing relevant changed, the doc is presumed still accurate and is not re-read in detail. This avoids the expensive "read every word in every doc and validate against code" approach.

**Behavior:**

1. For each doc in `docs/`, read its latest changelog entry to get a baseline SHA (and date) in the VS Code repo.
2. For each doc, gather the set of code references it makes (file paths, class/function names, directories).
3. Compute the set of VS Code commits between each doc's baseline SHA and the current HEAD. Inspect the changed files / symbols in that commit range.
4. Intersect the changed paths/symbols with the references each doc makes. Docs with no overlap are flagged as "presumed current" and skipped — no re-validation needed.
5. For docs with overlap, drill in: read the relevant changed code (and the relevant commits) and compare against the doc's description. Decide whether the doc is still accurate, has stale references, or has semantic drift.
6. Separately, do a cheap mechanical pass for any references that point to files or symbols that have been deleted, renamed, or moved entirely (regardless of baseline), since those are unambiguous staleness signals.
7. Produce a drift report: docs presumed current, docs with stale references, docs with semantic drift, and which VS Code commits triggered each finding.
8. Optionally, update the docs in place with corrected references and descriptions, appending a changelog entry noting the drift correction and the new baseline SHA.

---

## Workflow

A typical session:

1. Create a VS Code worktree for a feature branch (or work in the main checkout).
2. Start a chat session and ask the agent to plan or implement. The agent runs `knowledge-init` automatically on first use — setting up a knowledge worktree if VS Code is in a worktree, or using the knowledge repo's main checkout otherwise.
3. The agent uses `knowledge-plan` for larger work, or jumps straight to `knowledge-implement` for smaller changes.
4. Do the work. Agent reads relevant docs and task guides as needed.
5. Run `knowledge-finalize` to capture what was learned, commit to the knowledge repo, and clean up any session worktree.

Periodically (e.g., weekly, or after a batch of teammates' PRs land):

6. Run `knowledge-drift` from the main checkout to find and fix stale docs.

---

## Design Decisions

**Why a separate repo, not gitignored files in the VS Code repo:** Gitignored files aren't version-controlled. The knowledge base needs its own history, branching, and the ability to be shared later without touching the VS Code repo.

**Why a VS Code agent plugin, not symlinks into the VS Code worktree:** An earlier design symlinked the knowledge repo into each VS Code worktree as `.knowledge/` so the agent could see it as part of the working tree. Shipping the skills as a plugin in this repo is simpler: the skills are namespaced under the plugin in VS Code, install in one step, and resolve the knowledge repo path from configuration. Nothing has to be added to (or excluded from) the VS Code worktree.

**Why a worktree-per-session for the knowledge repo only when VS Code is in a worktree:** Concurrent agent sessions in VS Code worktrees can step on each other if they share a single knowledge checkout, so each gets its own knowledge worktree on a matching branch. When working in the main VS Code checkout there's no parallelism concern, so the agent operates on the knowledge repo's main checkout directly. `knowledge-finalize` does not need a worktree of its own — it just commits to the session's branch wherever that branch is checked out.

**Why flat `docs/` instead of mirroring the VS Code repo's directory structure:** The VS Code repo is deep and complex. Mirroring it would create empty directories, hard-to-find files, and maintenance overhead. Flat files with descriptive names and cross-references in `index.md` are easier to browse and maintain. Docs reference the VS Code paths they cover, which is sufficient for navigation and drift detection.

**Why `changes/` is separate from `docs/`:** Docs are mutable descriptions of the current state. Changes are an immutable log of what happened. They serve different purposes: docs answer "how does this work?" and changes answer "why is it this way?" and "what was tried?" Both are useful, and conflating them would make docs bloated with historical narrative.

**Why drift detection is driven by the VS Code Git history, not by re-reading every doc:** The naive approach — read each doc, re-read every code reference, compare — is expensive and scales badly as the knowledge base grows. The Git history is the cheaper signal: if nothing in the VS Code repo has changed in the area a doc describes since that doc's baseline, the doc is presumed still accurate. Only docs whose subject area has churned need a deeper read. This makes drift checks fast enough to run routinely.

**Why changelog SHAs reference the working branch, not the merge commit:** Recording the merge-to-main SHA would require coming back to the knowledge repo after the PR merges, which adds friction and will be forgotten. The working branch SHA is good enough — it anchors the entry in time, gives drift detection a baseline to diff against, and can be correlated with a PR if needed. Precision isn't worth the workflow cost.