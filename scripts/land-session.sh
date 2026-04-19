#!/usr/bin/env bash
# Commit the current session's knowledge worktree, fast-forward-merge it into
# main, push, and clean up the worktree + branch + .knowledge symlink.
#
# Usage:
#   scripts/land-session.sh [-m "commit message"] [--no-push]
#
# Output: machine-parseable `key: value` lines on stdout, ending with `status: ...`.
# Exit codes:
#   0 — landed (or nothing-to-land); ready
#   2 — not-fast-forward (session branch or main has diverged); resolve manually
#   3 — no-summary (finalize hasn't been run for this session)
#   4 — link-missing (no .knowledge symlink, or it's broken)
#   5 — main-checkout-unavailable (KNOWLEDGE_REPO is dirty or not on main)
#   1 — any other error

set -euo pipefail

MSG=""
PUSH=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) MSG="$2"; shift 2 ;;
        --no-push) PUSH=0; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# --- Resolve KNOWLEDGE_REPO from script location -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KNOWLEDGE_REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Resolve VSCODE_REPO from cwd --------------------------------------------
VSCODE_REPO="$(git rev-parse --show-toplevel)"
SUPER="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
[[ -n "$SUPER" ]] && VSCODE_REPO="$SUPER"

LINK="$VSCODE_REPO/.knowledge"
emit() { printf '%s: %s\n' "$1" "$2"; }

emit vscode-repo "$VSCODE_REPO"
emit knowledge-repo "$KNOWLEDGE_REPO"
emit knowledge-link "$LINK"

# --- Validate symlink --------------------------------------------------------
if [[ ! -L "$LINK" || ! -d "$LINK/" ]]; then
    emit status link-missing
    echo "error: $LINK is not a valid knowledge symlink; run init first" >&2
    exit 4
fi

WT="$(readlink "$LINK")"
KNOWLEDGE_BRANCH="$(git -C "$WT" symbolic-ref --short HEAD)"
emit knowledge-worktree "$WT"
emit knowledge-branch "$KNOWLEDGE_BRANCH"

if [[ "$KNOWLEDGE_BRANCH" == "main" ]]; then
    emit status on-main
    echo "error: session worktree is on 'main'; nothing to land" >&2
    exit 1
fi

# --- Fetch origin so we can identify what THIS session contributed -----------
# A `summary.md` for a *prior* session lives on main forever after that session
# was landed; we only consider summaries that are new in this session, i.e.
# either uncommitted in the working tree or committed since the branch diverged
# from origin/main.
git -C "$WT" fetch origin main >/dev/null 2>&1 || true
HAVE_ORIGIN=0
git -C "$WT" rev-parse --verify origin/main >/dev/null 2>&1 && HAVE_ORIGIN=1

# --- Find this session's summary --------------------------------------------
session_paths() {
    git -C "$WT" status --porcelain -uall | awk '{print $NF}'
    if [[ "$HAVE_ORIGIN" -eq 1 ]]; then
        git -C "$WT" diff --name-only origin/main..HEAD 2>/dev/null
    fi
}

SLUGS="$(session_paths | grep -E '^changes/[^/]+/summary\.md$' | awk -F/ '{print $2}' | sort -u || true)"
SLUG_COUNT=0
[[ -n "$SLUGS" ]] && SLUG_COUNT="$(printf '%s\n' "$SLUGS" | wc -l | tr -d ' ')"

if [[ "$SLUG_COUNT" -eq 0 ]]; then
    emit status no-summary
    echo "error: no new changes/<slug>/summary.md in this session; run finalize first" >&2
    exit 3
fi
if [[ "$SLUG_COUNT" -gt 1 ]]; then
    emit status multiple-summaries
    echo "error: multiple new summaries in this session: $(echo "$SLUGS" | tr '\n' ' '); resolve manually" >&2
    exit 1
fi
SESSION_SLUG="$SLUGS"
emit session-slug "$SESSION_SLUG"

if [[ -z "$MSG" ]]; then
    TITLE="$(awk '/^# /{sub(/^# /,""); print; exit}' "$WT/changes/$SESSION_SLUG/summary.md")"
    MSG="${TITLE:-$SESSION_SLUG}"
fi
emit commit-message "$MSG"

# --- Stage + commit any pending finalize edits -------------------------------
DIRTY="$(git -C "$WT" status --porcelain)"
if [[ -n "$DIRTY" ]]; then
    git -C "$WT" add -A
    git -C "$WT" commit -m "$MSG" >/dev/null
    emit committed yes
else
    emit committed no
fi

# --- Fast-forward session branch over origin/main ----------------------------
if [[ "$HAVE_ORIGIN" -eq 1 ]]; then
    if ! git -C "$WT" merge --ff-only origin/main >/dev/null 2>&1; then
        emit status not-fast-forward
        echo "error: session branch '$KNOWLEDGE_BRANCH' cannot fast-forward over origin/main;" >&2
        echo "       resolve manually (rebase or merge), then re-run" >&2
        exit 2
    fi
fi

AHEAD="$(git -C "$WT" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
emit commits-to-land "$AHEAD"
if [[ "$AHEAD" -eq 0 ]]; then
    emit status nothing-to-land
    echo "note: session branch has no commits beyond origin/main; nothing to merge" >&2
    exit 0
fi

# --- Validate main checkout (KNOWLEDGE_REPO) ---------------------------------
MAIN_BRANCH="$(git -C "$KNOWLEDGE_REPO" symbolic-ref --short HEAD 2>/dev/null || echo "")"
if [[ "$MAIN_BRANCH" != "main" ]]; then
    emit status main-checkout-unavailable
    echo "error: $KNOWLEDGE_REPO is on '$MAIN_BRANCH', not 'main'; switch it before landing" >&2
    exit 5
fi

MAIN_DIRTY="$(git -C "$KNOWLEDGE_REPO" status --porcelain)"
if [[ -n "$MAIN_DIRTY" ]]; then
    emit status main-checkout-unavailable
    echo "error: $KNOWLEDGE_REPO has uncommitted changes; commit or stash before landing" >&2
    exit 5
fi

# --- Bring main up to origin/main and ff-merge the session branch ------------
git -C "$KNOWLEDGE_REPO" fetch origin main >/dev/null 2>&1 || true
if git -C "$KNOWLEDGE_REPO" rev-parse --verify origin/main >/dev/null 2>&1; then
    if ! git -C "$KNOWLEDGE_REPO" merge --ff-only origin/main >/dev/null 2>&1; then
        emit status not-fast-forward
        echo "error: $KNOWLEDGE_REPO main cannot fast-forward to origin/main; resolve manually" >&2
        exit 2
    fi
fi

if ! git -C "$KNOWLEDGE_REPO" merge --ff-only "$KNOWLEDGE_BRANCH" >/dev/null 2>&1; then
    emit status not-fast-forward
    echo "error: main cannot fast-forward to $KNOWLEDGE_BRANCH; resolve manually" >&2
    exit 2
fi

LANDED_SHA="$(git -C "$KNOWLEDGE_REPO" rev-parse --short=10 HEAD)"
emit landed-sha "$LANDED_SHA"

# --- Push --------------------------------------------------------------------
if [[ "$PUSH" -eq 1 ]]; then
    git -C "$KNOWLEDGE_REPO" push origin main >/dev/null
    emit pushed yes
else
    emit pushed no
fi

# --- Clean up: symlink, worktree, branch -------------------------------------
rm "$LINK"
git -C "$KNOWLEDGE_REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
git -C "$KNOWLEDGE_REPO" branch -D "$KNOWLEDGE_BRANCH" >/dev/null 2>&1 || true

emit status landed
