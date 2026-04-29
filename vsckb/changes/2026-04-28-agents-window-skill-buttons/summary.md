# Sync built-in skills to agent hosts and implement blue skill buttons

**Date:** 2026-04-29
**VS Code branch:** roblou/agents/sync-built-in-skills-agent-hosts
**VS Code SHA at finalize:** fa1adf3685
**PR:** [#313277](https://github.com/microsoft/vscode/pull/313277)

## What was done

Two related features were implemented together as a revival of [PR #311815](https://github.com/microsoft/vscode/pull/311815), which had become too stale to rebase:

1. **Blue skill buttons for agent-host sessions.** Four action buttons (Merge Changes, Create PR, Create Draft PR, Update PR) are shown in `MenuId.ChatEditingSessionApplySubmenu` when the current session is an agent-host session. They are gated on context keys: `AgentHostSessionContext` (session is agent-host-backed) and `IsAgentHostSession` (reused from the sessions window for parity). The "Merge Changes" button is additionally gated behind `!agentHost.branchProtected`, which reads the `git.branchProtection` setting against the session's working directory. Buttons call the corresponding built-in skills (`/create-pr`, `/create-draft-pr`, `/update-pr`, `/merge-changes`) via `IChatService.sendRequest`.

2. **Syncing built-in skills to agent hosts.** Built-in skills are packaged alongside user and workspace customizations into the `vscode-synced-customization://` virtual bundle (already understood by remote agent hosts). The new work was: (a) extending `enumerateLocalCustomizationsForHarness` to also enumerate the `BUILTIN_STORAGE` skills, wrapped in a try/catch because `PromptsServiceImpl` throws for unknown storage types; (b) registering `AgentHostClientFileSystemProvider` in the **local** (utility-process) agent host so it can read the same bundle — this was an oversight in the original remote-only implementation.

To make (b) work, a new IPC channel `AgentHostClientResourceChannel` was introduced. The remote AH path used bidirectional AHP WebSocket reverse-RPC for free; the local AH path uses VS Code's one-way `MessagePort / UtilityProcessServer` IPC and had no way to originate reverse requests. The fix registers a second server channel on the renderer's `MessagePortClient`, which the utility-process AH reads back through `getChannel(AGENT_HOST_CLIENT_RESOURCE_CHANNEL, c => c.ctx === clientId)`.

A separate bug was fixed: `readBranchProtectionPatterns` was passing `project.uri` (canonical repo root) as the resource scope for the `git.branchProtection` configuration lookup. In a worktree, VS Code registers the **worktree path** as the workspace folder — not the canonical root — so the scoped lookup silently returned undefined. Fixed to pass `workingDirectory ?? project.uri`.

## Key decisions

- **New IPC channel rather than bundling to disk.** The virtual-bundle approach was already working for remote AHs; the goal was parity. Bundling to a temp path on disk would have diverged local and remote paths and introduced edge cases around cleanup. The `AgentHostClientResourceChannel` reverse-channel pattern is the canonical extension point for any future client-side resource the local AH needs to read.
- **Reuse `IsAgentHostSession` from the sessions window.** Rather than defining a new context key for the "is this session agent-host backed" check in the workbench, the existing key was reused. This keeps the two contexts in sync without duplicating the key registration logic.
- **BUILTIN_STORAGE wrapped in try/catch.** The regular `PromptsServiceImpl` throws (rather than returns `[]`) for storage types it doesn't recognize, including `BUILTIN_STORAGE`. Rather than changing the service contract or adding a separate code path, the `enumerateLocalCustomizationsForHarness` function wraps the lookup in a try/catch and logs a warning. The corresponding test was updated to model the throw rather than an empty return.

## What went wrong or was misunderstood

- **Local AH was never registered with `AgentHostClientFileSystemProvider`.** The original PR #311815 implemented the virtual-bundle sync only for remote AHs. When local AH support landed separately, the file-system provider registration wasn't added. The root cause was assuming that all AH paths share the same provider-registration code, without checking the local utility-process startup path (`agentHostMain.ts`) separately. — **prevented by:** new "Reverse RPC: remote AH vs local AH" section in `agent-host-topology.md` and the matching gotcha.
- **`BUILTIN_STORAGE` is not a `PromptsStorage` enum member.** It's a sentinel known only to `AgenticPromptsService` (the Sessions app's implementation). Passing it to `PromptsServiceImpl` (the workbench implementation) throws rather than returning `[]`. The original code assumed silent empty-return. — **prevented by:** new gotcha in `agent-host-customizations.md`.
- **`git.branchProtection` is resource-scoped; worktree paths don't match canonical repo root.** Passing `project.uri` (e.g. `file:///Users/roblou/code/vscode`) as the VS Code config resource scope returns undefined in a worktree because VS Code registered the worktree path (e.g. `file:///Users/roblou/code/vscode.worktrees/my-branch`) as the workspace folder. — **prevented by:** new gotcha in `agent-host-sessions-providers.md`.
- **Remote AH reverse-RPC is free via AHP WebSocket; local AH is not.** The assumption was that the two paths would be symmetric. The asymmetry required designing the `AgentHostClientResourceChannel` IPC layer from scratch. Understanding this upfront would have front-loaded the design discussion. — **prevented by:** new "Reverse RPC" section in `agent-host-topology.md`.

## What we learned

- Scanning both `agentHostMain.ts` (local) and `agentHostServerMain.ts` (remote) startup paths when registering any new provider or channel is load-bearing. These two files are the divergence point for local-vs-remote behavior.
- `IPCClient` in VS Code implements both `IChannelClient` AND `IChannelServer`, making reverse-RPC via a separate named channel a clean pattern for utility-process scenarios where one-way proxy channels aren't sufficient.

## Doc updates

- `docs/agent-host-customizations.md` — added table row for `BUILTIN_STORAGE` skills, new section "Builtin storage (Sessions app only)", new gotcha for `BUILTIN_STORAGE` sentinel, changelog entry.
- `docs/agent-host-sessions-providers.md` — added gotcha for `readBranchProtectionPatterns` worktree resource scope, changelog entry.
- `docs/agent-host-topology.md` — added "Reverse RPC: remote AH vs local AH" section, matching gotcha for `AgentHostClientResourceChannel`, changelog entry.
- Deleted `plan/2026-04-28-agents-window-skill-buttons/`.
