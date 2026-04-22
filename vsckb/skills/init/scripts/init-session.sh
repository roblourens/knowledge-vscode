#!/usr/bin/env bash
# Initialize a knowledge-repo worktree for the current VS Code session and
# expose it as `<vscode-repo>/.knowledge`. Idempotent within a session;
# refuses to clobber a previous session's in-flight work unless --force-fresh.
#
# Usage:
#   scripts/init-session.sh [--force-fresh]
#
# Output: machine-parseable `key: value` lines on stdout, ending with `status: ...`.
# Exit codes:
#   0 — created or reused; ready to use
#   2 — stale-with-work (previous session left commits or uncommitted changes);
#       agent should report this to the user, then re-run with --force-fresh
#   3 — conflict (`.knowledge` exists but isn't ours); agent should stop
#   1 — any other error

set -euo pipefail

FORCE_FRESH=0
for arg in "$@"; do
    case "$arg" in
        --force-fresh) FORCE_FRESH=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

# --- Resolve KNOWLEDGE_REPO from script location -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# --- Resolve VSCODE_REPO + branch from cwd -----------------------------------
VSCODE_REPO="$(git rev-parse --show-toplevel)"
SUPER="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
[[ -n "$SUPER" ]] && VSCODE_REPO="$SUPER"
VSCODE_BRANCH="$(git -C "$VSCODE_REPO" symbolic-ref --short HEAD)"

# --- Decide knowledge branch, disambiguating with -2/-3/... ------------------
in_use() {
    git -C "$KNOWLEDGE_REPO" worktree list --porcelain \
        | awk -v b="refs/heads/$1" '$1=="branch" && $2==b {found=1} END{exit !found}'
}
KNOWLEDGE_BRANCH="$VSCODE_BRANCH"
i=2
while in_use "$KNOWLEDGE_BRANCH"; do
    KNOWLEDGE_BRANCH="${VSCODE_BRANCH}-${i}"
    i=$((i+1))
done

KNOWLEDGE_WORKTREE="$KNOWLEDGE_REPO/.worktrees/$KNOWLEDGE_BRANCH"
LINK="$VSCODE_REPO/.knowledge"

emit() { printf '%s: %s\n' "$1" "$2"; }

# --- Inspect existing .knowledge ---------------------------------------------
EXISTING_STATUS=""        # ours-clean | ours-with-work | broken | foreign | none
EXISTING_TARGET=""
if [[ -L "$LINK" ]]; then
    EXISTING_TARGET="$(readlink "$LINK")"
    if [[ ! -d "$LINK/" ]]; then
        EXISTING_STATUS="broken"
    elif [[ "$EXISTING_TARGET" == "$KNOWLEDGE_REPO/.worktrees/"* ]]; then
        # It's one of ours. Decide whether it has work to preserve.
        DIRTY="$(git -C "$LINK" status --porcelain)"
        # Commits on its branch beyond origin/main (if origin/main exists).
        AHEAD=0
        if git -C "$KNOWLEDGE_REPO" rev-parse --verify origin/main >/dev/null 2>&1; then
            AHEAD="$(git -C "$LINK" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
        fi
        if [[ -z "$DIRTY" && "$AHEAD" -eq 0 ]]; then
            EXISTING_STATUS="ours-clean"
        else
            EXISTING_STATUS="ours-with-work"
        fi
    else
        EXISTING_STATUS="foreign"
    fi
elif [[ -e "$LINK" ]]; then
    EXISTING_STATUS="foreign"
else
    EXISTING_STATUS="none"
fi

emit vscode-repo "$VSCODE_REPO"
emit vscode-branch "$VSCODE_BRANCH"
emit knowledge-repo "$KNOWLEDGE_REPO"

# --- Handle each existing-status case ----------------------------------------
case "$EXISTING_STATUS" in
    foreign)
        emit knowledge-link "$LINK"
        emit existing-target "$EXISTING_TARGET"
        emit status conflict
        echo "error: $LINK exists and is not managed by this skill; refusing to touch it" >&2
        exit 3
        ;;
    ours-with-work)
        emit knowledge-link "$LINK"
        emit existing-worktree "$EXISTING_TARGET"
        emit existing-branch "$(git -C "$LINK" symbolic-ref --short HEAD)"
        emit existing-dirty-files "$(git -C "$LINK" status --porcelain | wc -l | tr -d ' ')"
        emit existing-commits-ahead "$AHEAD"
        if [[ "$FORCE_FRESH" -ne 1 ]]; then
            emit status stale-with-work
            echo "error: prior session's worktree has uncommitted changes or unpushed commits;" >&2
            echo "       re-run with --force-fresh to discard and start over" >&2
            exit 2
        fi
        # Force-fresh: tear down the old worktree.
        rm "$LINK"
        OLD_WT="$EXISTING_TARGET"
        OLD_BRANCH="$(git -C "$KNOWLEDGE_REPO" worktree list --porcelain \
            | awk -v p="$OLD_WT" '$1=="worktree" && $2==p {wt=1} wt && $1=="branch" {sub("refs/heads/","",$2); print $2; exit}')"
        git -C "$KNOWLEDGE_REPO" worktree remove --force "$OLD_WT" || true
        if [[ -n "$OLD_BRANCH" && "$OLD_BRANCH" != "main" ]]; then
            git -C "$KNOWLEDGE_REPO" branch -D "$OLD_BRANCH" 2>/dev/null || true
        fi
        ;;
    broken)
        rm "$LINK"
        ;;
    ours-clean)
        # Reusable: same skill setup, no work pending. Reuse it.
        emit knowledge-worktree "$EXISTING_TARGET"
        emit knowledge-branch "$(git -C "$LINK" symbolic-ref --short HEAD)"
        emit status reused
        exit 0
        ;;
    none)
        ;;
esac

# --- Create the worktree -----------------------------------------------------
mkdir -p "$KNOWLEDGE_REPO/.worktrees"
if git -C "$KNOWLEDGE_REPO" show-ref --verify --quiet "refs/heads/$KNOWLEDGE_BRANCH"; then
    git -C "$KNOWLEDGE_REPO" worktree add "$KNOWLEDGE_WORKTREE" "$KNOWLEDGE_BRANCH" >/dev/null
else
    BASE=main
    git -C "$KNOWLEDGE_REPO" show-ref --verify --quiet refs/heads/main || BASE=master
    git -C "$KNOWLEDGE_REPO" worktree add -b "$KNOWLEDGE_BRANCH" "$KNOWLEDGE_WORKTREE" "$BASE" >/dev/null
fi

# --- Symlink + .git/info/exclude --------------------------------------------
ln -s "$KNOWLEDGE_WORKTREE" "$LINK"
# Use --git-common-dir so this works when VSCODE_REPO is itself a worktree
# (in which case $VSCODE_REPO/.git is a file pointing to the real gitdir,
# not a directory — but info/exclude lives in the shared common dir anyway).
GIT_COMMON_DIR="$(git -C "$VSCODE_REPO" rev-parse --git-common-dir)"
case "$GIT_COMMON_DIR" in
    /*) ;;
    *) GIT_COMMON_DIR="$VSCODE_REPO/$GIT_COMMON_DIR" ;;
esac
EXCLUDE="$GIT_COMMON_DIR/info/exclude"
[[ -f "$EXCLUDE" ]] || { mkdir -p "$(dirname "$EXCLUDE")"; : > "$EXCLUDE"; }
grep -qxF '.knowledge' "$EXCLUDE" || echo '.knowledge' >> "$EXCLUDE"

emit knowledge-worktree "$KNOWLEDGE_WORKTREE"
emit knowledge-branch "$KNOWLEDGE_BRANCH"
emit status created
