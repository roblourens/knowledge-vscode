#!/usr/bin/env bash
set -euo pipefail

KNOWLEDGE_REMOTE="git@github.com:roblourens/knowledge-vscode.git"
START_DIR="${1:-$PWD}"

VSCODE_REPO="$(git -C "$START_DIR" rev-parse --show-toplevel)"

remote_matches_knowledge_repo() {
	local remote_url="$1"
	case "$remote_url" in
		git@github.com:roblourens/knowledge-vscode.git|https://github.com/roblourens/knowledge-vscode.git|https://github.com/roblourens/knowledge-vscode)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

is_knowledge_repo() {
	local repo="$1"
	[[ -d "$repo/docs" && -d "$repo/plan" && -d "$repo/changes" && -d "$repo/vsckb" ]] || return 1
	local origin_url
	origin_url="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
	remote_matches_knowledge_repo "$origin_url"
}

if is_knowledge_repo "$VSCODE_REPO"; then
	KNOWLEDGE_REPO="$VSCODE_REPO"
else
	KNOWLEDGE_REPO="$VSCODE_REPO/.knowledge-vscode"

	if [[ ! -e "$KNOWLEDGE_REPO/.git" ]]; then
		if git -C "$VSCODE_REPO" ls-files --error-unmatch .gitmodules >/dev/null 2>&1; then
			echo "error: .gitmodules is already tracked in $VSCODE_REPO; refusing to modify a tracked parent metadata file" >&2
			exit 2
		fi

		if [[ -e "$KNOWLEDGE_REPO" ]]; then
			echo "error: $KNOWLEDGE_REPO exists but is not a git checkout" >&2
			exit 3
		fi

		git -C "$VSCODE_REPO" submodule add -f "$KNOWLEDGE_REMOTE" .knowledge-vscode
		git -C "$VSCODE_REPO" reset -q -- .gitmodules .knowledge-vscode
	fi
fi

git -C "$KNOWLEDGE_REPO" fetch origin --quiet

printf 'VSCODE_REPO=%s\n' "$VSCODE_REPO"
printf 'KNOWLEDGE_REPO=%s\n' "$KNOWLEDGE_REPO"
printf 'KNOWLEDGE_REMOTE=%s\n' "$KNOWLEDGE_REMOTE"