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

**Retrieval:** For now, retrieval is intentionally simple — `index.md` plus keyword/search through `docs/` and `tasks/` is the whole story. Each doc and task entry in `index.md` should include a one-line description rich enough that keyword search finds it, plus a `Covers:` listing of the VS Code paths it concerns. If the knowledge base grows large enough that this stops being enough, we can add tags, embeddings, or a smarter retrieval skill later.

### `docs/`

Each file covers **one component or concern** within the agent host. "Component" is deliberately loose — it can be:

- a single file,
- a single class within a file,
- a folder or coherent set of files that work together,
- or a cross-cutting concern (a protocol, a lifecycle, a pattern).

The rule of thumb: a doc should have a small, declarable set of paths in the VS Code repo that it is *primarily* concerned with. If you can't list them in a sentence or two, the doc is probably trying to cover too much and should be split.

Each doc:

- Declares the VS Code paths it primarily covers (in a frontmatter block or a `Covers:` line near the top), so `knowledge-reconcile` knows which Git history to diff against.
- Describes what the component is and what it does.
- Explains how to work with it — key files, entry points, patterns to follow.
- Describes how it relates to other components, with cross-references to other docs.
- References specific files, classes, and functions in the VS Code repo by path. These references are what `knowledge-reconcile` validates.
- Ends with a **changelog section**: a reverse-chronological list of entries, each with a date, Git SHA, and short description of what changed in the component or in this doc's understanding of it.

**Cross-linking between docs:** Use plain Markdown links with relative paths (e.g., `[state sync protocol](./state-sync-protocol.md)`). Mention related docs inline where they're relevant rather than collecting them into a separate "See also" section — the goal is for an agent reading one doc to be naturally pulled to adjacent context. `index.md` is the only place that tries to be exhaustive about what exists.

**Every new doc starts with an initial changelog entry** — there is no doc without a baseline. The SHA used for that initial entry depends on context:

- If the doc is describing existing state in the VS Code repo, use the current HEAD of `main`.
- If the doc is describing something that's part of an in-flight change, use the current HEAD of whatever branch is checked out, even if it's a feature branch. (This case is a little TBD and may be refined later.)

The changelog SHAs reference whatever commit was HEAD on the working branch at the time the entry was written. These don't need to be updated later when the PR merges to main — they serve as approximate anchors for "around when did this understanding change" and as the baseline `knowledge-reconcile` diffs against, not as precise audit markers.

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

**Concurrency:** Multiple VS Code worktrees can each have their own knowledge worktree, and multiple sessions on the *same* VS Code branch (e.g., the same task being run with different models for comparison) each get their own knowledge branch and worktree as well — disambiguated by appending a short suffix when a branch name is already in use. The point is that no two concurrent sessions ever share a knowledge checkout or branch, so they can't influence each other's docs/plans/changes mid-flight. Since knowledge docs change less frequently than code, merge conflicts at finalize time will be rare and easy to resolve (they're just prose).

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

**Purpose:** Capture what was learned in this session back into the knowledge repo as on-disk changes, ready for the user to review and commit.

**Behavior:**

Finalize writes changes into the session's knowledge checkout (worktree if one was created, otherwise the main checkout on the session's branch). It does **not** commit, push, merge, or remove worktrees — that's the user's call after reviewing the diff. Cleanup of the session's `plan/` subfolder is the only on-disk deletion finalize performs.

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
5. Delete this session's subfolder under `plan/`.
6. Report the resulting diff to the user so they can review, commit, and (optionally) merge / clean up the session worktree themselves.

### `knowledge-reconcile`

**Purpose:** Detect drift between the knowledge docs and the current VS Code codebase, and **update the docs in place** to match. The goal of this skill is reconciliation, not reporting — a drift report is a side effect, not the deliverable.

(Originally called `knowledge-drift`. Renamed because the skill's job is to *fix* drift, not just describe it.)

**Precondition:** Knowledge repo is set up. If not, run `knowledge-init` automatically before continuing.

**Key idea:** Each doc has a baseline anchor — the most recent changelog entry's SHA (and date) recording the last time the doc was reconciled with the code. Reconciliation works by looking at what has changed in the VS Code repo *since* that baseline and asking whether any of those changes touch what the doc describes. If nothing relevant changed, the doc is presumed still accurate and is not re-read in detail. This avoids the expensive "read every word in every doc and validate against code" approach.

**Behavior:**

1. For each doc in `docs/`, read its declared `Covers:` paths and its latest changelog entry to get a baseline SHA (and date).
2. For each doc, gather the set of code references it makes (file paths, class/function names, directories) in addition to the declared paths.
3. Compute the set of VS Code commits between each doc's baseline SHA and the current HEAD of `origin/main` (not local `main`, which may be stale). If the baseline SHA no longer exists in `origin/main`'s history (e.g., the branch it was on was rebased or abandoned), fall back to `git log --since=<baseline date> -- <covers paths>`. Inspect the changed files and symbols in that commit range.
4. Intersect the changed paths/symbols with each doc's covered paths and references. Docs with no overlap are presumed current and skipped — no re-validation needed.
5. For docs with overlap, drill in: read the relevant changed code (and the relevant commits) and compare against the doc's description. Update the doc in place to reflect the current state, and append a changelog entry noting the reconciliation and the new baseline SHA.
6. Separately, do a cheap mechanical pass for any references that point to files or symbols that have been deleted, renamed, or moved entirely (regardless of baseline) — fix those too.
7. Summarize what was changed (which docs were updated, which were presumed current, which VS Code commits drove each update) so the user can review the diff.

---

## Workflow

A typical session:

1. Create a VS Code worktree for a feature branch (or work in the main checkout).
2. Start a chat session and ask the agent to plan or implement. The agent runs `knowledge-init` automatically on first use — setting up a knowledge worktree if VS Code is in a worktree, or using the knowledge repo's main checkout otherwise.
3. The agent uses `knowledge-plan` for larger work, or jumps straight to `knowledge-implement` for smaller changes.
4. Do the work. Agent reads relevant docs and task guides as needed.
5. Run `knowledge-finalize` to capture what was learned as on-disk changes in the knowledge repo. Review the diff, then commit (and optionally merge / remove the session worktree) yourself.

Periodically (e.g., weekly, or after a batch of teammates' PRs land):

6. Run `knowledge-reconcile` from the main checkout to update stale docs against the current VS Code codebase.

---

## Design Decisions

**Why a separate repo, not gitignored files in the VS Code repo:** Gitignored files aren't version-controlled. The knowledge base needs its own history, branching, and the ability to be shared later without touching the VS Code repo.

**Why a VS Code agent plugin, not symlinks into the VS Code worktree:** An earlier design symlinked the knowledge repo into each VS Code worktree as `.knowledge/` so the agent could see it as part of the working tree. Shipping the skills as a plugin in this repo is simpler: the skills are namespaced under the plugin in VS Code, install in one step, and resolve the knowledge repo path from configuration. Nothing has to be added to (or excluded from) the VS Code worktree.

**Why a worktree-and-branch per session for the knowledge repo:** Two concerns push toward isolation. (1) Concurrent sessions in different VS Code worktrees can both want to write docs/plans/changes; sharing a single knowledge checkout would mean stepping on each other's working tree state. (2) It's common to run the *same task* in parallel sessions — e.g., comparing different models on the same problem — and those sessions should not see each other's in-progress docs or plans, otherwise they influence each other. A branch + (when applicable) worktree per session gives each one a clean room. Since knowledge docs change infrequently and most sessions touch different docs, the merge cost at finalize time is low. `knowledge-finalize` does not need a worktree of its own beyond what `knowledge-init` already set up.

**Why mostly flat `docs/` instead of mirroring the VS Code repo's directory structure:** The VS Code repo is deep and complex. Mirroring it would create empty directories, hard-to-find files, and maintenance overhead, and it would also force each doc to live at one canonical location even though many docs cut across the tree (protocols, lifecycles, patterns). Flat files with descriptive names, declared `Covers:` paths, and cross-references in `index.md` are easier to browse and maintain. We're starting flat and will revisit if the file count grows past what's comfortable to skim.

**Why `changes/` is separate from `docs/`:** Docs are mutable descriptions of the current state. Changes are an immutable log of what happened. They serve different purposes: docs answer "how does this work?" and changes answer "why is it this way?" and "what was tried?" Both are useful, and conflating them would make docs bloated with historical narrative.

**Why drift detection is driven by the VS Code Git history, not by re-reading every doc:** The naive approach — read each doc, re-read every code reference, compare — is expensive and scales badly as the knowledge base grows. The Git history is the cheaper signal: if nothing in the VS Code repo has changed in the area a doc describes since that doc's baseline, the doc is presumed still accurate. Only docs whose subject area has churned need a deeper read. This makes reconciliation cheap enough to run routinely.

**Why `knowledge-reconcile` updates docs in place rather than producing a report:** A drift report that the user has to act on adds friction and tends to rot. The point of running reconciliation is to *end up with current docs*, not to know how stale things are. The skill writes the updates and leaves the user to review the diff and commit — same shape as `knowledge-finalize`.

**Why `knowledge-finalize` doesn't commit:** Finalize writes a meaningful diff into the knowledge repo (doc updates, a new `changes/` entry, plan cleanup). Auto-committing it would mix agent-generated content into history without a review step, and bundling commit + merge + worktree-removal into the skill makes it both fragile and hard to undo. Leaving commit and any worktree cleanup to the user keeps the skill simple, makes the diff reviewable, and matches `knowledge-reconcile`'s shape.

**Why changelog SHAs reference the working branch, not the merge commit:** Recording the merge-to-main SHA would require coming back to the knowledge repo after the PR merges, which adds friction and will be forgotten. The working branch SHA is good enough — it anchors the entry in time, gives drift detection a baseline to diff against, and can be correlated with a PR if needed. Precision isn't worth the workflow cost.