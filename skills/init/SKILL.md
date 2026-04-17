---
name: init
description: "Set up the VS Code agent host knowledge repo for the current session. Use when starting work that touches the agent host subsystem, or when any other skill in this plugin needs the repo and it hasn't been initialized yet. Triggers include 'init knowledge', 'set up knowledge repo', or any first invocation of plan / implement / finalize / reconcile in this session."
---

# Skill: init

Prepares the VS Code agent host knowledge repo for use in the current session. Other skills in this plugin run this automatically on first use — the user should never be told "run init first."

## Run the script

`init-session.sh` does all the work — branch naming, worktree creation, the `.knowledge/` symlink, and the `.git/info/exclude` line:

```sh
"$KNOWLEDGE_REPO/scripts/init-session.sh"
```

Resolve `KNOWLEDGE_REPO` from the user's VS Code setting if they have one configured; otherwise fall back to the repo this `SKILL.md` ships in (three directories up from this file).

The script prints `key: value` lines on stdout, ending with `status: ...`. Parse the output and react to `status`:

| `status` | exit | What happened | What to do |
|---|---|---|---|
| `created` | 0 | Fresh worktree set up. | Continue. |
| `reused` | 0 | An existing `.knowledge/` from this skill is clean and reusable. | Continue. |
| `stale-with-work` | 2 | A previous conversation left a worktree with uncommitted changes or unpushed commits. The script refused to touch it. | **If this is a new conversation** (you didn't make those changes), tell the user: "I found a leftover knowledge worktree at `<existing-worktree>` from a prior session — `<existing-dirty-files>` uncommitted file(s), `<existing-commits-ahead>` unpushed commit(s). I'm going to discard it and start fresh." Then re-run with `--force-fresh`. **If this is mid-conversation and the changes are yours**, do **not** re-run with `--force-fresh` — the existing symlink is what your skill should be using. |
| `conflict` | 3 | `$VSCODE_REPO/.knowledge` exists and isn't ours (real file/dir, or symlink to somewhere unexpected). | Surface the conflict to the user and stop. Don't touch it. |

## Session state — re-derive, don't persist

The skills don't store session state in agent memory. Every skill re-derives what it needs from the filesystem each time it runs:

- `KNOWLEDGE_CHECKOUT` = `"$VSCODE_REPO/.knowledge"` — the symlink path itself. Use it directly; don't `realpath` it. Filesystem ops, `git -C "$KNOWLEDGE_CHECKOUT" ...`, and reading/writing files under it all work transparently through the symlink. If the symlink is missing or broken (`[ ! -d "$KNOWLEDGE_CHECKOUT/" ]`), run `init` again.
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
1. The knowledge worktree path and branch (from the script's `knowledge-worktree` / `knowledge-branch` lines).
2. Whether it was `created`, `reused`, or recreated after `stale-with-work`.
3. That `.knowledge/` is now symlinked into the VS Code worktree (and excluded from Git).
4. A one-line summary of what the knowledge base currently covers.
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
- Run `git symbolic-ref --short HEAD` to get the current branch (`VSCODE_BRANCH`).

If the workspace doesn't look like the VS Code repo (no `package.json` with `"name": "code-oss-dev"` at the root), warn the user and ask whether to proceed anyway.

## Determining the knowledge branch

The knowledge branch name mirrors `VSCODE_BRANCH`. To support running the same task in parallel sessions (e.g., model bake-offs) without those sessions seeing each other's in-progress work, disambiguate when the branch is already in use:

1. `KNOWLEDGE_BRANCH = VSCODE_BRANCH`
2. If a worktree of `KNOWLEDGE_REPO` is already checked out on `KNOWLEDGE_BRANCH` (check `git -C "$KNOWLEDGE_REPO" worktree list`), append a short suffix: `KNOWLEDGE_BRANCH = "${VSCODE_BRANCH}-2"`, `-3`, etc., until you find an unused name.

## Setting up the checkout

Every session uses its own worktree of the knowledge repo. This is unconditional — even when VS Code is in its main checkout, the knowledge side still gets a worktree. It keeps the flow uniform, and it prevents two concurrent sessions from ever fighting over the knowledge repo's main checkout.

1. Decide the worktree path: `KNOWLEDGE_WORKTREE="$KNOWLEDGE_REPO/.worktrees/$KNOWLEDGE_BRANCH"`.
2. If `KNOWLEDGE_BRANCH` already exists locally in `KNOWLEDGE_REPO`, run `git -C "$KNOWLEDGE_REPO" worktree add "$KNOWLEDGE_WORKTREE" "$KNOWLEDGE_BRANCH"`.
3. Otherwise create it from `main`: `git -C "$KNOWLEDGE_REPO" worktree add -b "$KNOWLEDGE_BRANCH" "$KNOWLEDGE_WORKTREE" main`.
4. Set `KNOWLEDGE_CHECKOUT="$KNOWLEDGE_WORKTREE"`.

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

- `KNOWLEDGE_CHECKOUT` = `"$VSCODE_REPO/.knowledge"` — the symlink path itself. Use it directly; don't `realpath` it. Filesystem ops, `git -C "$KNOWLEDGE_CHECKOUT" ...`, and reading/writing files under it all work transparently through the symlink. If the symlink is missing or broken (`[ ! -d "$KNOWLEDGE_CHECKOUT/" ]`), run `init` again.
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
1. The knowledge worktree path being used.
2. The knowledge branch.
3. That `.knowledge/` is now symlinked into the VS Code worktree (and excluded from Git).
4. A one-line summary of what the knowledge base currently covers.
