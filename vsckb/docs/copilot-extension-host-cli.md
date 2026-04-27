# Copilot Extension-Host CLI Reference

_Covers: extensions/copilot/src/extension/chatSessions/copilotcli/, extensions/copilot/src/extension/chatSessions/vscode-node/chatSessions.ts, src/vs/platform/agentHost/node/copilot/_

When this codebase or contributor discussion refers to **"the Copilot extension"**, **"the Copilot CLI extension"**, **"extension-host CLI"**, or **"extension-host Copilot CLI"**, the current source is `extensions/copilot/` inside the VS Code repository. The pieces that mirror Agent Host behavior live primarily under `extensions/copilot/src/extension/chatSessions/copilotcli/`; registration happens in `extensions/copilot/src/extension/chatSessions/vscode-node/chatSessions.ts` through `registerCopilotCLIServices(...)` / `registerCopilotCLIServicesV1(...)` and `vscode.chat.registerChatSessionContentProvider(...)`.

Use this implementation as a parity and product-behavior reference when adding SDK-backed Agent Host features. Do not copy it blindly: the extension-host CLI is constrained by extension API shape, private SDK surfaces, and older session architecture. Agent Host should translate learned behavior into AHP-native protocol/state/provider concepts.

Key files often consulted alongside Agent Host work:

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` — the extension-host session class around the private Copilot CLI SDK. Permission, plan-mode, request lifecycle, telemetry, and tool event handling often have useful parity references here.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCli.ts` — model and SDK service wrappers for the extension-host CLI path.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts` — `handleReadPermission`, `handleWritePermission`, `handleShellPermission`, `handleMcpPermission`, plus the generic prompt fallback. Agent Host permission handling in `CopilotAgentSession` is a parallel implementation of the same user-facing behavior.
- `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` — SDK tool rendering, tool-call interpretation, prompt/reference extraction, and related chat UI data conversion.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/mcpHandler.ts` — extension-host MCP gateway forwarding, built-in GitHub MCP fallback, and custom-agent tool-name remapping.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/exitPlanModeHandler.ts` — plan-mode exit flow in the extension-host CLI path.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/logger.ts` and `copilotCliBridgeSpanProcessor.ts` — request logging and OTel bridge references.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCLISkills.ts` — skill conversion and SDK-facing customization behavior in the extension-host path.

## Parity gaps relevant to Agent Host

The Agent Host Copilot provider already owns the local SDK client, models, session lifecycle, session config, worktree creation, shell tools, permissions, customization conversion, and SDK event mapping. When comparing it with the extension-host Copilot CLI implementation, the remaining relevant gaps are mostly around making the session shippable and diagnosable rather than core lifecycle.

The most important gap is that `_resolveSessionWorkingDirectory` creates an isolated git worktree and branch, but the provider layer has no equivalent of the extension-host request lifecycle that commits or checkpoints dirty worktree state after a turn. Worktree creation is necessary for selfhosting, but not sufficient for shipping: without a turn-end commit/checkpoint flow, edits can remain only as uncommitted files in the worktree and be invisible to a parent-repo merge or PR flow. The Agent Host does now produce **per-session file diffs** for the "Branch changes" view (see [agent-host-git-driven-diffs](./agent-host-git-driven-diffs.md)); these diffs are driven by `git diff` against the merge-base of the session's base branch, so terminal-driven changes are included. This is not the same as auto-committing or checkpointing: the diff view shows what changed, but the changes remain as working-tree files.

MCP support exists through plugin conversion (`toSdkMcpServers`), but the provider does not currently mirror the extension-host `CopilotCLIMCPHandler` behavior that proxies all VS Code-configured MCP servers through the gateway, adds the built-in GitHub MCP fallback, and remaps custom-agent tool names from friendly names to gateway names. Treat that as a capability gap; the exact extension HTTP/lock-file transport is not necessarily the right Agent Host shape.

Provider logging is broad (`CopilotAgentSession._subscribeForLogging`), but it is not the same as the extension-host request logger and OTel bridge. For selfhosting investigations, the useful parity target is correlated turn/request/tool/hook/span diagnostics, not necessarily the same extension implementation.

For the **`skill` tool**, Agent Host intentionally diverges from EH CLI parity. The EH CLI's `formatSkillInvocation` only sees the `skill` tool's args (`{ skill: <name> }`) and so renders "Invoking skill: <name>". Agent Host hides the raw `skill` tool and synthesizes a tool-call display from the SDK's `skill.invoked` lifecycle event, which carries `{ name, path, description, ... }` — the resulting "Reading skill [name]" link is clickable and (for `SKILL.md` basenames) is upgraded to a rich skill pill client-side. See [copilot-sdk-tool-display#skill-events](./copilot-sdk-tool-display.md#skill-events). This is the canonical "translate, don't copy" precedent: when the SDK gives Agent Host more than the EH CLI sees, Agent Host can render better than EH CLI parity would suggest.

## Debt & gotchas

- **debt** (2026-04-21, copilotAgent.ts:_resolveSessionWorkingDirectory) — worktree isolation creates the branch/worktree but does not provide the extension-host CLI's turn-end auto-commit/checkpoint lifecycle. Add provider/protocol-side checkpoint or commit metadata before relying on Agent Host worktree sessions as shippable branches.
- **debt** (2026-04-21, copilotPluginConverters.ts:toSdkMcpServers) — plugin MCP conversion exists, but the Agent Host path does not yet mirror extension-host MCP gateway forwarding, built-in GitHub MCP fallback, or custom-agent tool-name remapping. Add an AHP-native bridge rather than copying extension HTTP/lock-file transport directly.
- **debt** (2026-04-21, copilotAgentSession.ts:_subscribeForLogging) — provider logging is broad but lacks the extension-host request/conversation logger and SDK OTel span bridge. Selfhosting needs correlated turn, tool, hook, and span diagnostics.
- **gotcha** (2026-04-22, copilotAgentSession.ts) — the Agent Host imports the **public** SDK `@github/copilot-sdk`. The Copilot CLI extension imports the **private** SDK `@github/copilot/sdk` (a sibling export from the same `@github/copilot` package). They expose substantially different surfaces. Concrete differences observed at `@github/copilot@1.0.34` / `@github/copilot-sdk@0.2.2`: private SDK accepts `agentMode` on `SendOptions`, exposes mutable `session.currentMode`, and exposes `Session.respondToExitPlanMode(requestId, response)`; public SDK lacks those surfaces even though the `exit_plan_mode.requested` event appears in the public event union. This is why `planning-mode session-state writes are auto-approved in default mode` in `protocol/toolApprovalRealSdk.integrationTest.ts` is currently skipped.

## Related

- [design-principles](./design-principles.md) — top-level terminology for Agent Host, extension-host CLI, and the original VS Code agent.
- [copilot-agent-provider](./copilot-agent-provider.md) — the Agent Host provider overview.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) — Agent Host permission behavior and callback safety.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — tool rendering parity references and display gotchas.

## Changelog

- **2026-04-26** — `b86149ad81` — updated "Parity gaps" to note that Agent Host now produces git-driven per-session file diffs for the "Branch changes" view (PR [#312632](https://github.com/microsoft/vscode/pull/312632)); clarified this is not the same as auto-commit/checkpoint — changes remain as working-tree files.
- **2026-04-25** — 89433a4490 — added skill-display divergence note to "Parity gaps relevant to Agent Host": Agent Host hides the raw `skill` tool and synthesizes its display from `skill.invoked` (path-aware, clickable, rendered as a skill pill), where the EH CLI's `formatSkillInvocation` is stuck on name-only because it only sees the tool args. Canonical "translate, don't copy" example for future SDK divergences.
- **2026-04-24** — 4b6403a3ab — split extension-host CLI reference and Agent Host parity gaps out of the Copilot provider overview
