# Copilot SDK Permissions

_Covers: src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts, src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts, src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts_

`CopilotAgentSession` handles Copilot SDK permission and user-input callbacks for the Agent Host provider. It is a parallel implementation of the extension-host CLI permission path in `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts`, but it should expose behavior through Agent Host/AHP concepts rather than sharing extension-host code directly.

## Session-state auto-approval

`CopilotAgentSession.handlePermissionRequest` auto-approves file reads and writes that target the session's own state directory: `~/.copilot/session-state/<sessionId>/`. This mirrors the Copilot CLI extension's behavior.

The trusted directory is derived by `getCopilotCLISessionStateDir()`:

1. Check `process.env.XDG_STATE_HOME` — if set, use `$XDG_STATE_HOME/.copilot/session-state`.
2. Otherwise use `INativeEnvironmentService.userHome.fsPath` + `/.copilot/session-state`.

The per-session path appends the session ID from `_getInternalSessionResourcePath`. Both the session directory and the incoming permission path are run through `normalizePath()` before `isEqualOrParent()` comparison, to prevent `..` traversal escapes. An additional guard checks that the session directory itself remains under the session-state root after normalization.

Write permission requests from the Copilot SDK use `request.fileName` for the target path; read requests use `request.path`. These are different shapes — not interchangeable.

Reference code in the Copilot CLI extension:

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/cliHelpers.ts` — `getCopilotCLISessionStateDir()` resolves the session-state root with XDG support.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts` — auto-approves reads and writes under the session-specific directory.

## SDK callback error logging

All callbacks handed to the Copilot SDK (`handlePermissionRequest`, `handleUserInputRequest`, pre/post tool use hooks, and client tool handlers) are wrapped in try/catch that logs via `logService.error()` then rethrows. This is necessary because the SDK catches unhandled callback exceptions and converts them into generic failures (for example, "Permission denied and could not request permission from user") with no logging. Without the wrapper, bugs like missing DI services produce untraceable permission denials.

## Debt & gotchas

- **gotcha** (2026-04-19, copilotAgentSession.ts:handlePermissionRequest) — Copilot SDK write permission requests identify the target via `request.fileName`, NOT `request.path`. Read requests use `request.path`. Mixing them up silently causes auto-approval to miss the target path and fall through to the user-confirmation codepath.
- **gotcha** (2026-04-19, copilotAgentSession.ts) — ALL callbacks handed to the Copilot SDK must wrap in try/catch + `logService.error()` + rethrow. The SDK silently swallows unhandled callback exceptions and converts them to generic error responses ("Permission denied", "Could not request input") with no logging. Without the wrapper, DI failures and other bugs in callbacks are untraceable.
- **gotcha** (2026-04-19, copilotAgentSession.ts:getCopilotCLISessionStateDir) — prefer `INativeEnvironmentService.userHome.fsPath` over `import { homedir } from 'os'` for the home directory. The service is available in the agent-host process (registered in both startup paths) and makes testing easier.

## Related

- [copilot-agent-provider](./copilot-agent-provider.md) — provider lifecycle and session ownership.
- [copilot-extension-host-cli](./copilot-extension-host-cli.md) — extension-host permission helper reference.
- [copilot-sdk-shells](./copilot-sdk-shells.md) — shell-tool permission asymmetry.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — permission display rendering for shell/custom tools.

## Changelog

- **2026-04-24** — 4b6403a3ab — split permission handling and SDK callback safety out of the Copilot provider overview
