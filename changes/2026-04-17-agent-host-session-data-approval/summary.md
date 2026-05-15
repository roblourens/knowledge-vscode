# Auto-Approve Copilot CLI Session-State Paths in Agent Host

**Date:** 2026-04-19
**VS Code branch:** roblou/copilot-cli-session-state-approval
**VS Code SHA at finalize:** bea3e7e018
**PR:** https://github.com/microsoft/vscode/pull/311206

## What was done

Mirrored the Copilot extension's session-state auto-approval behavior in the agent host's `CopilotAgentSession`. The Copilot CLI (running in the extension host) auto-approves reads and writes to `~/.copilot/session-state/<sessionId>/` without prompting the user. The agent host's Copilot session now does the same, so features like plan mode can write `plan.md` to that directory without a confirmation dialog — even in default (non-auto-approve) mode.

Beyond the core auto-approval, the session also grew:
- **Traversal-safe path normalization** — `normalizePath()` before `isEqualOrParent()` to prevent `..` segment attacks.
- **Try/catch error logging on all SDK callbacks** — `handlePermissionRequest`, `handleUserInputRequest`, `_handlePreToolUse`, `_handlePostToolUse`, and client tool `handler` all log via `logService.error()` and rethrow. Previously, exceptions were silently swallowed by the SDK and surfaced as vague "Permission denied" with no log trace.
- **`INativeEnvironmentService` DI wiring** — registered the environment service in both agent-host startup paths (`agentHostMain.ts`, `agentHostServerMain.ts`); `CopilotAgentSession` uses `userHome.fsPath` instead of `os.homedir()`.

## Key decisions

- **The auto-approval lives in `CopilotAgentSession`, not generic `AgentSideEffects`.** The trusted path `~/.copilot/session-state/` is Copilot-specific (decided by the SDK), not an agent-host-generic concept. Other providers would have their own trusted directories.
- **Native-only environment service registration.** The agent-host child process has no consumers of `IEnvironmentService` (the base token) — only `INativeEnvironmentService`. We register only the native token, consistent with the fact that the process is always a Node process (never web). The parent-process starter (`nodeAgentHostStarter.ts`) does use `IEnvironmentService`, but that runs in the main Electron process's DI container, not the child's.
- **XDG_STATE_HOME is checked separately from the environment service.** There's no VS Code service that surfaces this env var, so `process.env.XDG_STATE_HOME` is read directly. The home directory fallback uses the service.

## What went wrong or was misunderstood

- **Wrong seam initially.** The plan targeted `AgentSideEffects._tryAutoApproveToolReady` and `SessionDataService`, assuming the trusted directory was the agent-host's generic session data directory. In reality it's the Copilot SDK's own `~/.copilot/session-state/` directory, which is Copilot-provider-specific. The correct seam is `CopilotAgentSession.handlePermissionRequest`. — **prevented by:** doc body update on [copilot-agent-provider](../docs/copilot-agent-provider.md) (now documents session-state auto-approval and the CopilotAgentSession permission handler).
- **`os.homedir()` used directly instead of environment service.** Initial implementation imported `homedir` from `os` directly. User corrected: prefer `INativeEnvironmentService.userHome` to stay consistent with the rest of the codebase and make testing easier. — **prevented by:** gotcha on copilot-agent-provider doc.
- **DI wiring regression — `INativeEnvironmentService` not registered in `agentHostMain.ts`.** After switching from `os.homedir()` to the environment service, the agent-host child process crashed with `undefined` on every permission check because the DI container never had the service registered. The error was invisible — the SDK swallowed the exception and returned "Permission denied." — **prevented by:** the new composition test in `copilotAgent.test.ts` (tests the real `_createAgentSession` path with the real DI setup), plus the new try-catch logging on all SDK callbacks.
- **SDK callbacks silently swallow exceptions.** When any callback handed to the Copilot SDK throws, the SDK catches it and converts it into a generic failure (e.g., "Permission denied and could not request permission from user") with no logging. Debugging this required manual bisection. — **prevented by:** gotcha on copilot-agent-provider doc; all callbacks now wrap in try/catch + `logService.error()` + rethrow.
- **Write permission `fileName` vs `path`.** The Copilot SDK permission request for writes puts the target in `request.fileName`, not `request.path`. This was only discovered by reading the Copilot CLI extension's `permissionHelpers.ts`. — **prevented by:** gotcha on copilot-agent-provider doc.

## What we learned

- The agent-host child process (`agentHostMain.ts`, `agentHostServerMain.ts`) does not need `IEnvironmentService` (the base token). Only `INativeEnvironmentService` is consumed. Other VS Code processes vary — some register both — but the agent host is native-only.
- Running agent-host unit tests from the CLI requires `env -u ELECTRON_RUN_AS_NODE` to disable the Electron env flag, otherwise the test runner fails to find Electron binaries.
- The Copilot CLI extension (running in the extension host) resolves session-state paths in `extensions/copilot/src/extension/chatSessions/copilotcli/node/cliHelpers.ts` via `getCopilotCLISessionStateDir()` with `XDG_STATE_HOME` support.
- `URI.file(path)` preserves `..` segments; you must `normalizePath()` before using `isEqualOrParent()` for security checks.

## Doc updates

- **Updated:** [copilot-agent-provider](../docs/copilot-agent-provider.md) — added "Session-State Auto-Approval" section documenting `CopilotAgentSession.handlePermissionRequest`, the trusted directory derivation, path normalization, and the reference Copilot CLI code. Added "SDK Callback Error Logging" section. Added three gotchas (write `fileName` vs `path`, SDK swallows exceptions, prefer environment service over `os.homedir()`). Added changelog entry.
- **Updated:** [agent-host-topology](../docs/agent-host-topology.md) — added gotcha about agent-host child process using only `INativeEnvironmentService`. Added changelog entry.
