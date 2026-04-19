# Prevent agent shell commands from polluting user shell history

**Date:** 2026-04-19
**VS Code branch:** agents/fix-issue-311245-vscode-skill-implement
**VS Code SHA at finalize:** e625d61aa4
**PR:** https://github.com/microsoft/vscode/pull/311251

## What was done

Mirrored VS Code's run-in-terminal tool behavior for agent-host managed shells. When `ShellManager` (in `copilotShellTools.ts`) creates a bash/PowerShell PTY through `IAgentHostTerminalManager.createTerminal`, it now passes a new `preventShellHistory: true` option, which sets `VSCODE_PREVENT_SHELL_HISTORY=1` on the spawned PTY env. The existing shell integration scripts (`shellIntegration-bash.sh`, `shellIntegration-rc.zsh`, `shellIntegration.ps1`) already pick that up to set `HISTCONTROL=ignorespace` / `HIST_IGNORE_SPACE` / a no-op PSReadLine `AddToHistoryHandler`.

Commands written to bash/zsh shells via `executeCommandWithShellIntegration` and `executeCommandWithSentinel` are now also prepended with a single space (via a new `prefixForHistorySuppression` helper). PowerShell needs no prefix because PSReadLine drops everything regardless.

## Key decisions

- **Always-on, not setting-gated.** The workbench equivalent (`toolTerminalCreator.ts` + `commandLinePreventHistoryRewriter.ts`) is gated on the `chat.tools.terminal.preventShellHistory` setting. The agent host has no equivalent setting today, and the leading space + env var are harmless when shell integration is missing or when the user's history-control settings happen to differ — so this just turns it on unconditionally for managed shells. If a setting is needed later, it should be plumbed in once at `ShellManager` creation.
- **`preventShellHistory` as a `createTerminal` option, not on `ICreateTerminalParams`.** The protocol shape for terminal creation is unchanged; this is a server-internal hint on the local Node implementation only. Adding it to AHP would require advertising it across local/remote and isn't justified for a one-shell-spawning consumer.
- **Don't change `agentService.createTerminal`.** Only the SDK shell tool path needs suppression; user-initiated terminal creates (e.g. through the protocol) should keep default history behavior.

## What went wrong or was misunderstood

- (none — existing knowledge was sufficient)

The session went smoothly: the workbench-side fix was easy to find (`CommandLinePreventHistoryRewriter` + the `VSCODE_PREVENT_SHELL_HISTORY` env-var convention), the agent host code paths involved are small and well-bounded (`ShellManager`, `executeCommandWithShellIntegration`, `executeCommandWithSentinel`, `AgentHostTerminalManager.createTerminal`), and the test surface was already isolated behind a `TestAgentHostTerminalManager` fake.

The one minor surprise — that `ShellType` and `prefixForHistorySuppression` weren't exported — was a self-imposed constraint that resolved by exporting them for tests. That's not a knowledge-base concern.

## What we learned

- The `copilotShellTools.ts` / `agentHostTerminalManager.ts` surface had no doc coverage at finalize time. Rather than create a standalone doc for a small fix, the relevant content was added as a section + Covers update on `copilot-agent-provider.md`. If that surface grows further (e.g. a real `chat.tools.terminal.preventShellHistory` equivalent setting, or richer shell types), it likely warrants its own doc.
- The shell-integration env-var convention (`VSCODE_PREVENT_SHELL_HISTORY`) is shared infrastructure with the workbench. Any change to its name or semantics needs to flow through both consumers (`toolTerminalCreator.ts` and `agentHostTerminalManager.ts`) — captured as a `gotcha:` on `copilot-agent-provider.md`.

## Doc updates

- **copilot-agent-provider.md** — added `copilotShellTools.ts` (and its test) to `Covers:`; added a "Managed shells" section describing `ShellManager` and the always-on shell-history suppression; added a `gotcha:` entry tying the leading-space prefix and the `VSCODE_PREVENT_SHELL_HISTORY` env var together.
