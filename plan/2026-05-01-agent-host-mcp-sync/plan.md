# Plan: Agent Host MCP Sync

Sync enabled VS Code MCP servers into local Agent Host sessions by extending the existing synthetic Open Plugin customization bundle with gateway-backed `.mcp.json` entries. Keep the first implementation local-Agent-Host-only: it should make the current "Bridged" UI true for local Agent Host sessions without trying to solve remote localhost/stdio placement in the same change.

## Knowledge context used

- [design-principles](../../docs/design-principles.md) — confirms Agent Host should translate Copilot/SDK behavior into AHP-native/provider-native concepts instead of copying extension-host plumbing blindly.
- [agent-host-customizations](../../docs/agent-host-customizations.md) — documents the existing local/remote customization providers, synthetic bundle, built-in skill sync, and related gotchas.
- [copilot-extension-host-cli](../../docs/copilot-extension-host-cli.md) — calls out MCP gateway forwarding as a known Agent Host parity gap and points at `CopilotCLIMCPHandler` as the behavior reference.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md) — documents `session/activeClientChanged` as the client customization/tool publication path.
- [agent-host-topology](../../docs/agent-host-topology.md) — constrains placement: workbench-side discovery/bridging belongs in the workbench/session adapter layer; provider SDK config belongs in `src/vs/platform/agentHost/node/copilot/`.
- [changes/2026-04-21-copilot-cli-agent-host-gap-audit](../../changes/2026-04-21-copilot-cli-agent-host-gap-audit/summary.md) — explicitly identifies "VS Code MCP gateway and built-in MCP parity are partial" and recommends an Agent Host-native bridge.

## Approach

Use the path that already works for Agent Host customizations: the client publishes Open Plugin refs via `session/activeClientChanged`, the Agent Host copies/parses those plugin dirs, and `CopilotAgent._buildSessionConfig` passes parsed MCP definitions to the SDK through `toSdkMcpServers(...)`. The missing piece is that `SyncedCustomizationBundler` never emits MCP definitions, even though `parsePlugin(...)` already understands `.mcp.json` and manifest `mcpServers`.

For local Agent Host, start and own an MCP gateway from the workbench side using `IWorkbenchMcpGatewayService.createGateway(false, sessionResource?)`, then add each gateway server to the synthetic bundle as HTTP MCP server config. This mirrors the extension-host CLI's product behavior in `CopilotCLIMCPHandler.loadMcpConfigWithGateway(...)`, but keeps the resulting data in the existing Open Plugin customization pipeline instead of adding a new protocol field. The generated `.mcp.json` should contain stable, SDK-safe server names derived from gateway labels, `type: "http"`, `url`, `tools: ["*"]`, and any display metadata the SDK type accepts if available through the plugin parser path.

Remote Agent Host should remain intentionally unsupported in this first pass. A gateway URL created on the local client is normally a localhost/local-port URL from the client's point of view; copying that URL into a plugin installed on a remote Agent Host would make the remote process connect to its own localhost, not the user's machine. Stdio MCP servers have the inverse problem: copying their command line to a remote Agent Host would run the command on the remote host, which is only correct for remote-host MCP configurations, not for local user MCP configurations. The simple safe rule is: local Agent Host gets gateway-backed MCP; remote Agent Host keeps MCP hidden/not synced until a follow-up introduces a remote-host gateway or AHP client-tool bridge.

The UI should stop overpromising. The current `mcpListWidget.ts` shows "Bridged" for every non-local customization harness, including remote Agent Host, with hover text claiming forwarding to all compatible sessions. As part of this implementation, make the badge reflect actual support: show it for harnesses whose descriptor/session type is local Agent Host or extension-host Copilot CLI if applicable, and hide it for remote Agent Host until remote MCP sync is implemented.

## Steps

### Phase 1: Workbench-side MCP bundle input

1. Add a small workbench-side MCP gateway bundling helper near `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts` or in a sibling file. It should normalize gateway server labels with the same constraints as `CopilotCLIMCPHandler.normalizeServerName`, produce deterministic names, and expose enough information for `.mcp.json` generation. Acceptance criteria: label normalization is deterministic, collision-safe, and covered by unit tests. — depends on: none
2. Extend `SyncedCustomizationBundler.bundle(...)` to accept optional MCP server entries in addition to prompt files, write `.plugin/plugin.json` as today, write `.mcp.json` when entries exist, and include the MCP content in the bundle nonce. Acceptance criteria: a bundle with only MCP entries still returns a `CustomizationRef`, and nonce changes when MCP server addresses or names change. — depends on: step 1
3. Add tests for `SyncedCustomizationBundler` covering prompt-only, MCP-only, prompt-plus-MCP, no-syncable-content, name collisions, and nonce stability. If no dedicated test file exists, add one under the existing workbench agent-host test area rather than testing this indirectly through session creation. — depends on: step 2

### Phase 2: Local Agent Host integration

4. Inject `IWorkbenchMcpGatewayService` into `AgentHostChatContribution` and create a gateway-backed MCP contribution for each local Agent Host harness. The lifetime should be owned by the same `DisposableStore` as the harness registration. Acceptance criteria: gateway disposal happens when the harness/provider store is disposed; no long-lived gateway is leaked after provider removal. — depends on: step 2
5. Update `resolveCustomizationRefs(...)` or wrap its call from `AgentHostChatContribution` so local Agent Host refs include the synthetic bundle whenever either loose prompt files or gateway MCP entries exist. Add change triggers from the gateway's `onDidChangeServers` and relevant MCP service/registry changes so `customizations` is recomputed and `AgentHostSessionHandler` re-dispatches `activeClientChanged`. Acceptance criteria: adding/removing/enabling/disabling an MCP server updates the local Agent Host customization refs without requiring a window reload. — depends on: step 4
6. Keep `remoteAgentHost.contribution.ts` unchanged for actual sync behavior in this phase, except for any signature updates required by shared helper changes. Acceptance criteria: remote Agent Host still does not receive local gateway URLs. — depends on: step 2

### Phase 3: Agent Host provider verification

7. Confirm no provider-side protocol change is needed: `parsePlugin(...)` already reads `.mcp.json`, `CopilotAgent._buildSessionConfig(...)` already calls `toSdkMcpServers(...)`, and `toSdkMcpServers(...)` already converts parsed definitions to SDK MCP config. Add or adjust tests only if the generated `.mcp.json` shape exposes parser/converter gaps. Acceptance criteria: parsed synthetic `.mcp.json` reaches SDK config as HTTP MCP server entries. — depends on: step 2
8. Add a focused integration-style unit test around local active-client customization sync if a practical harness exists: simulate gateway MCP entries, dispatch active-client customizations, and assert `setClientCustomizations(...)` / parsed plugin state includes MCP servers. Acceptance criteria: the test proves the end-to-end data path from synthetic bundle to provider parser without needing real MCP servers. — depends on: steps 2 and 7

### Phase 4: UI honesty and docs

9. Update `mcpListWidget.ts` badge logic so "Bridged" only appears for harnesses that actually bridge MCP servers. Prefer adding an explicit capability/flag to `IHarnessDescriptor` over hard-coding string IDs if that is not too invasive; otherwise use a narrow local helper with comments and tests. Acceptance criteria: remote Agent Host no longer claims MCP servers are bridged. — depends on: phase 2 decision on supported harnesses
10. Update Agent Host knowledge/docs after implementation, likely in `agent-host-customizations.md` and `copilot-extension-host-cli.md`, to replace the current MCP parity-gap statement with the implemented local-only behavior and a remaining remote-MCP debt note. Acceptance criteria: docs distinguish local gateway-backed sync from unsupported remote-host sync. — depends on: implementation complete

## Relevant files

- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts` — extend synthetic Open Plugin generation to include `.mcp.json` and MCP-aware nonce content.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostLocalCustomizations.ts` — adapt `resolveCustomizationRefs(...)` inputs or add an adjacent helper so loose files and MCP gateway entries are bundled together.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts` — local Agent Host harness owner; create/dispose gateway and recompute `customizations` on MCP changes.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts` — should remain local-MCP-sync-free; only update for shared signature churn if needed.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/platform/agentPlugins/common/pluginParsers.ts` — existing parser for `.mcp.json` via `readMcpServers(...)` and `parseMcpServerDefinitionMap(...)`; ideally reused unchanged.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/platform/agentHost/node/copilot/copilotPluginConverters.ts` — existing `toSdkMcpServers(...)`; ideally reused unchanged.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/platform/agentHost/node/copilot/copilotAgent.ts` — existing `_buildSessionConfig(...)` consumes parsed plugin MCP servers; likely no change.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/workbench/contrib/mcp/common/mcpGatewayService.ts` and platform-specific implementations — source for gateway creation and lifetime semantics.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/src/vs/workbench/contrib/chat/browser/aiCustomization/mcpListWidget.ts` — "Bridged" badge should match actual Agent Host support.
- `/Users/roblou/code/vscode.worktrees/agents-mcp-server-sync-investigation/extensions/copilot/src/extension/chatSessions/copilotcli/node/mcpHandler.ts` — reference behavior only, especially name normalization and gateway-backed SDK config shape.

## Verification

1. Run `npm run compile-check-ts-native` after TypeScript changes.
2. Run focused unit tests for `SyncedCustomizationBundler` once added.
3. Run existing Agent Host provider tests around plugin conversion/parsing, especially `src/vs/platform/agentHost/test/node/copilotPluginConverters.test.ts` and any new parser/bundler tests.
4. Run focused workbench agent-host tests covering `AgentHostChatContribution` or `resolveCustomizationRefs(...)` if added.
5. Manually verify in a local Agent Host session that an enabled VS Code MCP server appears in the synthetic plugin `.mcp.json`, is copied by `AgentPluginManager.syncCustomizations(...)`, is parsed by `parsePlugin(...)`, and reaches SDK `mcpServers`.
6. Manually verify in a remote Agent Host harness that MCP servers are not synced and the UI does not claim they are bridged.

## Decisions

- Use gateway-backed HTTP MCP entries for local Agent Host rather than copying raw VS Code MCP definitions. This handles stdio and local-port servers uniformly from the SDK's point of view and reuses existing MCP enablement/trust/start behavior.
- Do not sync local gateway URLs to remote Agent Host in this change. This avoids the common localhost bug where the remote process interprets the user's local port as remote localhost.
- Do not copy stdio command definitions to remote Agent Host in this change. Running a copied command remotely is only correct for remote-host MCP configuration, and the current customization pipeline does not encode that ownership clearly enough.
- Do not add an AHP protocol field for MCP servers yet. Existing customization refs already have plugin sync, cache, status, and parser support; `.mcp.json` fits that model.
- Keep built-in GitHub MCP fallback out of the first implementation unless it naturally appears through the existing MCP service/gateway. The immediate ask is enabled VS Code MCP servers, not extension-host CLI fallback parity.

## Risks and open questions

- Gateway address lifetime must line up with Agent Host session lifetime. If the gateway is harness-scoped, it may outlive individual sessions, which is simple but could keep MCP resources running longer than necessary.
- Name normalization/collisions must be stable because custom agents may refer to server/tool names. The extension-host CLI has remapping logic that Agent Host does not yet mirror.
- Some HTTP MCP servers with auth headers or OAuth may need gateway-only handling; direct config copying would be riskier, which is why this plan avoids it.
- Remote Agent Host users may still expect MCP sync because the UI has trained them to expect "Bridged". The first implementation should make the UI honest and leave remote support as explicit debt.
- If `IWorkbenchMcpGatewayService` is unavailable in some local Agent Host environments, the bundler should omit MCP entries and log visibly rather than silently claiming sync.

## Docs that will need updating

- [agent-host-customizations](../../docs/agent-host-customizations.md) — add local MCP gateway-backed synthetic bundle behavior and note remote is intentionally unsupported.
- [copilot-extension-host-cli](../../docs/copilot-extension-host-cli.md) — narrow the MCP parity gap from "missing" to "local gateway-backed sync exists; remote/native bridge and tool-name remapping remain".
- [agent-host-topology](../../docs/agent-host-topology.md) — possibly add a gotcha/decision note that local client MCP is bridged via synthetic customizations, while remote Agent Host needs a remote-host gateway or AHP-native bridge.
