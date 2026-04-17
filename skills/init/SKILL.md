---
name: init
description: "Set up the VS Code agent host knowledge repo for the current session. Use when starting work that touches the agent host subsystem, or when any other skill in this plugin needs the repo and it hasn't been initialized yet. Triggers include 'init knowledge', 'set up knowledge repo', or any first invocation of plan / implement / finalize / reconcile in this session."
---

# Skill: init

Prepares the VS Code agent host knowledge repo for use in the current session. Other skills in this plugin run this automatically on first use — the user should never be told "run init first."

## Resolving the knowledge repo path

Resolve `KNOWLEDGE_REPO` (the absolute path to the knowledge repo) in this order:

1. The VS Code setting that points at the knowledge repo, if the user has configured one. (Setting name is user-managed; check workspace and user settings for any setting whose value is an absolute path containing this skill's parent directories.)
2. Fall back to the repo this skill ships in: this `SKILL.md` lives at `<KNOWLEDGE_REPO>/skills/init/SKILL.md`, so `KNOWLEDGE_REPO` is the directory three levels up from this file.

If neither resolves, ask the user where the knowledge repo lives and stop.

## Resolving the VS Code repo

Resolve `VSCODE_REPO` from the current working directory:

- Run `git rev-parse --show-toplevel` from the workspace root to get the repo root.
- Run `git rev-parse --show-superproject-working-tree` to detect submodules; use the superproject if present.
- Run `git rev-parse --git-dir` and check whether the path contains `.git/worktrees/` — that means VS Code is checked out as a worktree (`IS_WORKTREE=1`), not the main checkout.
- Run `git symbolic-ref --short HEAD` to get the current branch (`VSCODE_BRANCH`).

If the workspace doesn't look like the VS Code repo (no `package.json` with `"name": "code-oss-dev"` at the root), warn the user and ask whether to proceed anyway.

## Determining the knowledge branch

The knowledge branch name mirrors `VSCODE_BRANCH`. To support running the same task in parallel sessions (e.g., model bake-offs) without those sessions seeing each other's in-progress work, disambiguate when the branch is already in use:

1. `KNOWLEDGE_BRANCH = VSCODE_BRANCH`
2. If a worktree of `KNOWLEDGE_REPO` is already checked out on `KNOWLEDGE_BRANCH` (check `git -C "$KNOWLEDGE_REPO" worktree list`), append a short suffix: `KNOWLEDGE_BRANCH = "${VSCODE_BRANCH}-2"`, `-3`, etc., until you find an unused name.

## Setting up the checkout

If `IS_WORKTREE=1` (VS Code is in a worktree):

1. Decide the worktree path: `KNOWLEDGE_WORKTREE="$KNOWLEDGE_REPO/.worktrees/$KNOWLEDGE_BRANCH"`.
2. If `KNOWLEDGE_BRANCH` already exists locally in `KNOWLEDGE_REPO`, run `git -C "$KNOWLEDGE_REPO" worktree add "$KNOWLEDGE_WORKTREE" "$KNOWLEDGE_BRANCH"`.
3. Otherwise create it from `main`: `git -C "$KNOWLEDGE_REPO" worktree add -b "$KNOWLEDGE_BRANCH" "$KNOWLEDGE_WORKTREE" main`.
4. Set `KNOWLEDGE_CHECKOUT="$KNOWLEDGE_WORKTREE"`.

If `IS_WORKTREE` is unset (VS Code is the main checkout):

1. Skip the worktree step. `KNOWLEDGE_CHECKOUT="$KNOWLEDGE_REPO"`.
2. If `KNOWLEDGE_BRANCH` exists locally, check it out: `git -C "$KNOWLEDGE_CHECKOUT" checkout "$KNOWLEDGE_BRANCH"`.
3. Otherwise create it from `main`: `git -C "$KNOWLEDGE_CHECKOUT" checkout -b "$KNOWLEDGE_BRANCH" main`.

Confirm the checkout is clean before continuing (`git -C "$KNOWLEDGE_CHECKOUT" status --porcelain`). If it isn't, surface the dirty files to the user and stop — don't silently overwrite.

## Symlinking into the VS Code worktree

For editing convenience, expose the session's knowledge checkout inside the VS Code workspace as `.knowledge/`. The skills don't *need* this symlink to function (they resolve `KNOWLEDGE_CHECKOUT` independently), but it makes the knowledge files browsable and editable in the same editor window as the code.

1. Target: `LINK="$VSCODE_REPO/.knowledge"`.
2. If `LINK` already exists:
   - If it's a symlink and resolves to `$KNOWLEDGE_CHECKOUT`, leave it alone.
   - If it's a symlink pointing somewhere else, or a regular file/directory, surface the conflict to the user and stop. Do not overwrite.
3. Otherwise create it: `ln -s "$KNOWLEDGE_CHECKOUT" "$LINK"`.
4. Make sure `.knowledge` is excluded from VS Code Git tracking by appending it to `$VSCODE_REPO/.git/info/exclude` if it isn't already a line in that file. (Use `info/exclude` rather than `.gitignore` so the exclusion is local to this clone and never leaks into upstream commits. Also covers worktrees — `info/exclude` lives under the main `.git` directory and applies to all linked worktrees.)

## Session state — re-derive, don't persist

The skills don't store session state in agent memory. Every skill re-derives what it needs from the filesystem each time it runs:

- `KNOWLEDGE_CHECKOUT` = `realpath "$VSCODE_REPO/.knowledge"` (the symlink). If the symlink is missing or broken, run `init` again.
- `KNOWLEDGE_BRANCH` = `git -C "$KNOWLEDGE_CHECKOUT" symbolic-ref --short HEAD`.
- `VSCODE_REPO`, `VSCODE_BRANCH` from `git rev-parse` against the workspace root.
- `SESSION_SLUG` (when needed) is the single subfolder under `$KNOWLEDGE_CHECKOUT/plan/` for this session. If there's exactly one, that's it; if there are zero, the skill that needs one (`plan`) creates it; if there are multiple, ask the user which session they're working in.

This keeps the system stateless from the agent's perspective and avoids the agent-memory dependency.

## Orienting the agent

Read `$KNOWLEDGE_CHECKOUT/index.md` and report a concise summary to the agent:

- Which docs and tasks exist (names + one-line descriptions).
- The most recent two or three entries in `changes/` (titles only).

Do not dump the full file contents — the agent will pull in specific docs as the task demands.

## Output

Tell the user exactly:
1. The knowledge checkout path being used and whether it's a worktree.
2. The knowledge branch.
3. That `.knowledge/` is now symlinked into the VS Code worktree (and excluded from Git).
4. A one-line summary of what the knowledge base currently covers.
