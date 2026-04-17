---
name: land
description: "Commit the current session's finalized knowledge edits, fast-forward-merge them into main, push, and clean up the worktree + .knowledge symlink. Use after the user has reviewed the diff produced by 'finalize' and is ready to publish. Triggers: 'land knowledge', 'publish knowledge', 'merge knowledge', 'ship knowledge'."
---

# Skill: land

Publish the session's knowledge changes back to `main` and tear down the session worktree.

This skill is the counterpart to `finalize`. `finalize` writes the diff for the user to review. `land` is what the user invokes once they're happy with that diff.

## Precondition

`finalize` must have run for this session — `land` refuses unless `$VSCODE_REPO/.knowledge/changes/<slug>/summary.md` exists.

## Run the script

```sh
scripts/land-session.sh                 # default
scripts/land-session.sh -m "<message>"  # override commit message
scripts/land-session.sh --no-push       # land locally but don't push origin/main
```

The script (in this order):

1. Stages and commits any pending edits in the session worktree (commit message comes from the first `# heading` of `summary.md`, or `-m`).
2. `git fetch origin main` and fast-forwards the session branch over `origin/main`. If not ff, stops.
3. Switches the main knowledge checkout (`KNOWLEDGE_REPO`) to `main`, ff-pulls `origin/main`, then ff-merges the session branch.
4. Pushes `main` to `origin` (unless `--no-push`).
5. Removes the `.knowledge` symlink, the session worktree, and the session branch.

## Status decisions

The script emits `key: value` lines and ends with `status: <code>`.

| `status:` | exit | what to do |
| --- | --- | --- |
| `landed` | 0 | Done. Tell the user the landed SHA and that `.knowledge` has been removed. |
| `nothing-to-land` | 0 | Session branch has no commits beyond `origin/main`. Nothing was merged. The worktree is left in place — tell the user. |
| `no-summary` | 3 | `finalize` hasn't been run. Run `finalize` first, let the user review, then re-run `land`. |
| `link-missing` | 4 | `.knowledge` is missing or broken. Something is wrong; ask the user before doing anything. |
| `not-fast-forward` | 2 | Either the session branch can't ff over `origin/main`, or `main` can't ff to the session branch. Surface the script's stderr to the user and stop — they need to rebase or resolve manually. |
| `main-checkout-unavailable` | 5 | `KNOWLEDGE_REPO` is dirty or not on `main`. Surface the message to the user; don't try to fix it. |
| `multiple-summaries` | 1 | More than one `changes/<slug>/summary.md` in the session worktree — unusual; ask the user which one to use. |
| `on-main` | 1 | Session worktree is somehow on `main`. Stop and ask. |
| anything else | 1 | Surface stderr to the user and stop. |

## Output

Tell the user the landed SHA (from `landed-sha:`), confirm `.knowledge` and the session branch are gone, and that they can start a fresh session next time. Don't run further commands.
