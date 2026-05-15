# Tasks: Agent Host MCP Sync

1. [x] Add MCP gateway bundle data structures and name normalization near `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts`.
   - depends on: none
   - acceptance: deterministic server names, collision handling, and unit coverage.
2. [x] Extend `SyncedCustomizationBundler.bundle(...)` to write `.mcp.json` from optional gateway MCP entries and include them in the nonce.
   - depends on: task #1
   - acceptance: MCP-only bundles return a `CustomizationRef`; nonce changes with MCP content.
3. [x] Add focused bundler tests for prompt-only, MCP-only, mixed prompt/MCP, no-content, collisions, and nonce stability.
   - depends on: task #2
   - acceptance: tests directly inspect the virtual plugin filesystem output.
4. [x] Integrate `IWorkbenchMcpGatewayService` into local `AgentHostChatContribution` and own the gateway lifetime in the harness `DisposableStore`.
   - depends on: task #2
   - acceptance: local Agent Host has gateway MCP entries available for bundling; gateway disposes with the harness.
5. [x] Recompute local Agent Host customization refs when gateway MCP servers change, and include gateway MCP entries when calling the bundler.
   - depends on: task #4
   - acceptance: MCP changes trigger `customizations` observable updates and `activeClientChanged` redispatch for active sessions.
6. [x] Keep `remoteAgentHost.contribution.ts` from syncing local MCP gateway URLs, adjusting only for shared helper signatures if required.
   - depends on: task #2
   - acceptance: remote Agent Host receives no client-local MCP gateway URLs.
7. [x] Verify or test the provider-side parser/converter path from generated `.mcp.json` through `parsePlugin(...)`, `toSdkMcpServers(...)`, and `CopilotAgent._buildSessionConfig(...)`.
   - depends on: task #2
   - acceptance: generated HTTP MCP entries reach SDK `mcpServers`.
8. [x] Update `mcpListWidget.ts` so the "Bridged" badge appears only for harnesses that actually bridge MCP servers.
   - depends on: task #5
   - acceptance: remote Agent Host no longer displays a misleading bridged badge.
9. [x] Run focused automated validation: TypeScript compile check, new bundler tests, relevant plugin converter/parser tests, MCP gateway tests, hygiene, and layer checks.
    - depends on: tasks #1-#8
    - acceptance: generated local MCP bundle parses through Agent Host plugin parsing; remote MCP remains unsynced and UI is honest.
10. [ ] Update knowledge docs after implementation.
    - depends on: task #9
    - acceptance: `agent-host-customizations.md`, `copilot-extension-host-cli.md`, and possibly `agent-host-topology.md` reflect local-only MCP sync and remaining remote debt.

## Discoveries for finalize

- Local Agent Host MCP sync now routes through the workbench MCP gateway and the existing synthetic Open Plugin customization bundle.
- The generated `.mcp.json` should preserve MCP server labels as user-visible/plugin parser names, only suffixing exact duplicate labels.
- The gateway should expose only enabled MCP servers; disabled servers are filtered before local Agent Host sync.
- Async customization recomputation must be versioned so older resolves cannot overwrite newer gateway-inclusive customization refs.
- Remote Agent Host MCP sync remains intentionally unsupported for now. Raw stdio remote sync may be viable later, but local gateway HTTP URLs must not be sent to remote Agent Hosts.
