# Local Agent Host & Extension CLI Coexistence

**Date:** 2026-04-21
**VS Code branch:** roblou/agents/local-agent-host-coexistence
**VS Code SHA at finalize:** 7bc767483b
**PR:** https://github.com/microsoft/vscode/pull/311600

## What was done

Removed the suppression gate in `DefaultSessionsProviderContribution` that prevented the extension-host `CopilotChatSessionsProvider` from registering when `chat.agentHost.enabled` was `true`. Both providers now register simultaneously. Each provider already filters to its own sessions — the local agent host uses a per-session SQLite database existence check, the extension uses per-session JSON metadata via `getSessionOrigin()` — so there is no session overlap.

To visually distinguish local-agent-host sessions in the sidebar, workspace labels now include a `[Local]` tag (e.g. `myrepo [Local]`), matching the existing remote provider's `${folderName} [${hostName}]` pattern. This is threaded via `buildAgentHostSessionWorkspace`'s existing `providerLabel` parameter.

Session-type labels (used in the filter menu and new-session picker) remain unadorned — no `[Local]` suffix — because `SessionsManagementService._collectSessionTypes()` deduplicates by `type.id` and both providers share the `copilotcli` id.

## Key decisions

- **No new ownership markers needed.** Both providers' existing filters are symmetric and sufficient. The agent host's database-existence gate and the extension's `getSessionOrigin()` filter naturally partition the session space.
- **`[Local]` on workspace labels only, not session-type labels.** The session-type dedup in `_collectSessionTypes()` is first-come-first-served by `type.id`. Since both providers share `copilotcli`, different labels would produce non-deterministic UI. Workspace labels are per-session so they're safe to tag.
- **Kept the fix for the stale `_groupModel` merge artifact.** `main` has a broken reference (`_groupModel.addChat(...)` at line 1795 of `copilotChatSessionsProvider.ts`) from an incomplete upstream cleanup in commit `6101c499fea`. Our branch carries a one-line removal of this reference to unblock CI; this shows in the PR diff even though we didn't intentionally touch that file.

## What went wrong or was misunderstood

- **Upstream refactor mid-flight.** Between planning and the first merge of `origin/main`, the `localAgentHost/` contrib folder was renamed to `agentHost/` and `LocalSessionAdapter` was replaced by `AgentHostSessionAdapter` with a callback-based `IAgentHostAdapterOptions` pattern. The initial implementation targeted the old class structure and had to be re-ported after the merge. **Prevented by:** nothing actionable — concurrent development is inherent. But the knowledge doc for [agent-host-sessions-providers](../docs/agent-host-sessions-providers.md) now documents the current architecture so future sessions start with the right mental model.
- **Session-type label dedup wasn't anticipated.** The initial implementation added `[Local]` to session-type labels (e.g. `Copilot [Local]`), not realizing that `_collectSessionTypes()` deduplicates by `type.id` across providers. Copilot code review caught this. **Prevented by:** gotcha added to [agent-host-sessions-providers § Debt & gotchas](../docs/agent-host-sessions-providers.md#debt--gotchas) documenting the dedup rule.
- **`ELECTRON_RUN_AS_NODE` env var breaks test runner.** The worktree shell had `ELECTRON_RUN_AS_NODE=1` set, which causes Electron to act as plain Node and fail with `app.setPath is not a function`. Had to `unset ELECTRON_RUN_AS_NODE` before `scripts/test.sh`. **Prevented by:** already documented in [testing.md](../docs/testing.md).
- **Stale `localAgentHost/` tracked files after rename.** Git continued tracking empty files under the old `src/vs/sessions/contrib/localAgentHost/` path after the upstream rename to `agentHost/`. These caused hygiene failures on commit. Had to `git rm -rf` them explicitly. **Prevented by:** nothing specific — this is a standard git worktree artifact when paths are renamed upstream.
- **Merge artifact: stale `_groupModel` reference on `main`.** The merge of `origin/main` produced a clean 3-way merge but left a stale `_groupModel.addChat(...)` call that upstream commit `6101c499fea` intended to remove. This was not a conflict (git merged adjacent-but-non-overlapping changes "cleanly") but the result was broken. Our branch had to remove it to pass CI, creating an unrelated diff in the PR. **Prevented by:** nothing — silent merge artifacts from adjacent non-overlapping changes are inherent to 3-way merge.

## What we learned

- The coexistence model between the agent-host provider and the extension-host provider is entirely filter-based — no registration-time gating is needed. This pattern could extend to other provider pairs in the future.
- `buildAgentHostSessionWorkspace` already supported `providerLabel` for the remote case; the local provider was the only one not using it. The infrastructure was already there.

## Doc updates

- **[agent-host-sessions-providers.md](../docs/agent-host-sessions-providers.md)** — added "Coexistence with the extension-host provider" section; updated `_formatSessionTypeLabel` hook doc; added gotcha for session-type label dedup; added changelog entry; fixed garbled trailing line.
- **[copilot-agent-provider.md](../docs/copilot-agent-provider.md)** — added coexistence paragraph to Session Ownership section cross-linking to the new sessions-providers section; added changelog entry.
