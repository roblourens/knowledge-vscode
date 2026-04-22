# Copilot CLI extension vs Agent Host gap audit

**Date:** 2026-04-21
**VS Code branch:** main
**VS Code SHA at finalize:** ad531180d0
**PR:** TBD

## What was done

Compared the extension-host Copilot CLI implementation against the local Copilot Agent Host provider, the Agent Host workbench chat adapter, and the Agent Host Sessions app providers. The result is a source-backed gap audit focused on what matters for Agent Host selfhosting and shipping code changes, rather than a blind list of every extension-host detail.

The audit identifies critical gaps, high-impact parity gaps, lower-priority product gaps, extension-only details that should probably not be copied, and core capabilities that Agent Host already covers well.

## Key decisions

- Treat the extension-host implementation as the reference feature inventory, but not as the architecture to copy. Agent Host should keep using AHP-native client tools, protocol state, terminal/filesystem bridges, and remote-capable abstractions where possible.
- Prioritize selfhosting and shipping changes over cosmetic parity. Worktree commit/checkpoint lifecycle, prompt/reference fidelity, shipping/PR flows, plan exit handling, MCP/client-tool parity, hook bundling, and observability are higher impact than external session adoption or multi-chat grouping.
- Keep the detailed audit in a `changes/` entry and record durable component debt in the relevant docs, rather than creating a broad comparison doc that would go stale quickly.

## What went wrong or was misunderstood

- The `.knowledge` setup looked valid because a symlink existed, but it was broken and then `init` created an empty worktree under the skill directory instead of the actual knowledge repo. This caused early reads of `.knowledge/index.md` and `.knowledge/docs` to fail and made it possible to write into the wrong checkout. — **prevented by:** this summary and an index debt pointer noting that the knowledge workflow needs a checkout-shape sanity check before writing or landing.
- The first audit draft was written directly as a `changes/` summary before running the finalize retrospective/doc-update pass. It had the useful comparison, but not the mandatory finalize metadata, retrospective, or doc debt updates. — **prevented by:** this summary and the new debt entries in the component docs that preserve the durable findings outside the narrative entry.
- The initial comparison underweighted worktree commit/checkpoint lifecycle because the Agent Host worktree creation path looked like strong parity at first glance. A later search for extension `autoCommit` / checkpoint services showed that "creates a worktree" and "produces a shippable branch" are different responsibilities. — **prevented by:** a new `debt:` entry in [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) and the P0 worktree section below.
- The initial comparison also treated attachments as generally present because `IAgentAttachment` supports selection text/ranges and the provider forwards them to the SDK. Reading `_convertVariablesToAttachments` showed the handler currently sends only the selection path/display name. — **prevented by:** a new request-context section and `debt:` entry in [agent-host-session-handler](../../docs/agent-host-session-handler.md#debt--gotchas).

## What we learned

- Agent Host already covers the core selfhosting substrate well: lifecycle, worktree/folder config, model/thinking config, permissions, terminal shells, edit tracking, subagents, steering, client tools, and local/remote sessions providers.
- The highest-impact missing pieces are not basic lifecycle features; they are the glue that makes the session operationally useful for local VS Code work: shippable worktree state, rich local context, plan/PR UX, MCP/client-tool defaults, hook sync, and diagnostics/logging.
- Some extension-host mechanisms should be translated, not copied. The in-process HTTP MCP server and lock-file transport solve extension-host constraints; Agent Host should usually prefer AHP-native equivalents.

## Doc updates

- Updated [copilot-agent-provider](../../docs/copilot-agent-provider.md) with a Copilot CLI parity-gap section and debt entries for worktree commit/checkpoint lifecycle, plan/PR/todo tool display, MCP gateway parity, and debug/request logging.
- Updated [agent-host-session-handler](../../docs/agent-host-session-handler.md) with request-context/client-tool parity notes and debt entries for selection attachment payloads, prompt/reference resolution, default VS Code client tools, and image attachments.
- Updated [index](../../index.md) with cross-cutting active debt pointers for the Copilot CLI parity audit and knowledge checkout-shape workflow miss.

## Audit details

This audit compares the extension-host Copilot CLI implementation with the local Copilot Agent Host provider and the Agent Host workbench/sessions adapters. It focuses on features and considerations that are relevant to the Agent Host path but are missing or only partially present there.

Priority key:

- **P0 / critical path**: likely to block selfhosting or shipping changes with the agent.
- **P1 / high impact**: important for parity, trust, debuggability, or common workflows.
- **P2 / product parity**: useful, visible, or expected, but not usually a selfhosting blocker.
- **P3 / probably not relevant**: extension transport/UI detail that Agent Host should not necessarily copy.

## Highest-impact gaps

### P0: Worktree changes are not committed/checkpointed for shipping

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/common/chatSessionWorktreeService.ts` defines worktree properties, `autoCommit`, checkpoint refs, and cleanup/recreate behavior.
- `extensions/copilot/src/extension/chatSessions/common/chatSessionWorktreeCheckpointService.ts` defines baseline and post-turn checkpoints.
- `extensions/copilot/src/extension/chatSessions/vscode-node/sessionRequestLifecycle.ts` is documented by `extensions/copilot/src/extension/chatSessions/copilotcli/AGENTS.md` as coordinating request start/end, worktree commits, checkpoints, PR detection, and metadata updates.
- `extensions/copilot/src/extension/chatSessions/common/folderRepositoryManager.ts` handles uncommitted-change prompts and migration into worktrees.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotAgent.ts` creates an isolated worktree in `_resolveSessionWorkingDirectory` using `IAgentHostGitService.addWorktree` and records the branch name.
- `src/vs/platform/agentHost/node/agentHostGitService.ts` only exposes basic git helpers: branch lookup, `worktree add`, and `worktree remove`.
- I did not find an Agent Host equivalent of turn-end auto-commit, baseline/post-turn git checkpoints, archive/unarchive worktree lifecycle, or uncommitted-change migration.

**Why it matters:** Selfhosting often means "make changes, then ship them." The extension path has a worktree lifecycle that creates commits/checkpoints so the branch contains the agent's work. The Agent Host path creates a branch/worktree, but if the agent leaves edits as uncommitted worktree changes, a parent-repo merge or PR flow can miss them. This is probably the largest critical-path gap for shipping changes from Agent Host sessions.

**Likely direction:** Add an Agent Host turn lifecycle around `SessionTurnStarted` / turn completion that can checkpoint and optionally commit dirty worktree changes, persist checkpoint/commit metadata, and expose enough state for the Sessions app apply/ship flows. This should be protocol-aware and work for remote Agent Hosts too, rather than copying extension-local services directly.

### P0: Prompt/reference resolution is much thinner in Agent Host

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliPromptResolver.ts` resolves files, directories, selections with text and ranges, diagnostics, prompt files, GitHub PR references, merge-change references, image binary data, ignore filtering, notebook exclusions, and worktree path translation.
- `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLIPrompt.ts` parses prompt references, including diagnostics and file/line references.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCLIImageSupport.ts` stores image data under extension global storage and marks those image files trusted for read permissions.

**Agent Host state:**

- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts` `_convertVariablesToAttachments` converts only basic file, directory, and implicit selection variables.
- For selections, `_convertVariablesToAttachments` currently sends `type`, `path`, and `displayName`, but not selected text or range, even though `IAgentAttachment` supports `text` and `selection` in `src/vs/platform/agentHost/common/agentService.ts` and `CopilotAgentSession.send` forwards those fields to the SDK when present.
- I did not find equivalents for diagnostics references, image attachments, PR/merge references, prompt-file filtering, ignored-file filtering, or multi-root worktree path translation.

**Why it matters:** Selfhosting depends heavily on precise local context. Losing selected text/ranges, diagnostics, image attachments, and PR/merge references makes the agent less capable and can make common "fix this selection/test/error" prompts underpowered or wrong. The missing selection payload looks especially high-impact because the types and SDK forwarding path already exist.

**Likely direction:** First fix selection text/range propagation. Then port the relevant parts of `CopilotCLIPromptResolver` into the Agent Host handler or a shared workbench service, keeping the transport generic as `IAgentAttachment` / AHP content references. Image support should be modeled as protocol content/resource references rather than extension global-storage files where remote hosts are involved.

### P0: Shipping commands and PR workflow parity are missing

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` defines CLI commands `compact`, `plan`, `fleet`, and `remote`, and built-in slash commands `/commit`, `/sync`, `/merge`, `/create-pr`, `/create-draft-pr`, `/update-pr`.
- The same file captures `create_pull_request` tool results and stores `_createdPullRequestUrl`.
- `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` has display handling for `create_pull_request`, `exit_plan_mode`, `skill`, `update_todo`, and other CLI-specific tools.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` only has explicit display handling for shell, file, grep/glob, web, ask-user, patch, and subagent basics. It does not include extension-specific display/capture for `create_pull_request`, `exit_plan_mode`, `skill`, `update_todo`, or slash-command shipping flows.
- I did not find Agent Host equivalents for `/commit`, `/sync`, `/merge`, `/create-pr`, `/create-draft-pr`, or `/update-pr` command handling.

**Why it matters:** The user specifically called out "using the agent and shipping changes." Even if the agent can edit files, the selfhosting loop needs a reliable way to commit/sync/merge/create PRs and surface the created PR URL. Relying on generic shell commands is possible but loses the product flow and structured success signals.

**Likely direction:** Decide whether these remain Copilot-specific tool/command conventions in the Agent Host provider or become generic AHP/session actions. At minimum, add Copilot provider display/result handling for PR creation and enough session metadata/events for the UI to offer the next shipping action.

### P1: Plan mode exit handling and plan artifacts are missing

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/exitPlanModeHandler.ts` handles `exit_plan_mode.requested`, presents Autopilot / Interactive / Exit Only / Autopilot Fleet choices, monitors `plan.md` for user edits, flushes saved plan changes back to the SDK, and returns the selected execution mode.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` updates artifacts with the current plan path through `setArtifacts`.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` handles permission requests and generic user input requests, but there is no `exit_plan_mode.requested` path in the Agent Host grep results.
- Session-state auto-approval already trusts `~/.copilot/session-state/<sessionId>/plan.md`, but the dedicated exit-plan UX is not present.

**Why it matters:** Plan mode is central to safer autonomous selfhosting. Without explicit exit-plan handling, the SDK may not be able to ask the user how to proceed from a generated plan, and edits to `plan.md` may not be synchronized back before execution.

**Likely direction:** Add an AHP representation for plan-exit requests or map the SDK event into the existing `user_input_request` model plus artifacts. The plan-file monitor probably belongs on the client/workbench side when the plan file is user-editable, while the final SDK response belongs in the provider session.

### P1: VS Code MCP gateway and built-in MCP parity are partial

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/mcpHandler.ts` `CopilotCLIMCPHandler.loadMcpConfig` starts the VS Code MCP gateway, normalizes server names, proxies all VS Code-configured MCP servers as HTTP servers, adds a built-in GitHub MCP server when gateway forwarding is disabled, and remaps custom-agent tool references from friendly names to gateway names.
- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/inProcHttpServer.ts` and `lockFile.ts` are the extension-host transport pieces for its VS Code tool server.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotPluginConverters.ts` converts parsed plugin MCP servers to SDK MCP server config.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts` sends active-client customizations and generic client tools, but I did not find gateway forwarding of the user's configured VS Code MCP servers or the built-in GitHub MCP fallback.

**Why it matters:** MCP tools are a major extension path for GitHub operations and external integrations. For selfhosting, missing the GitHub MCP path can weaken PR/issue/repo workflows, and missing gateway remapping can make custom agents reference tools that the SDK cannot resolve.

**Likely direction:** Prefer an Agent Host-native bridge from VS Code MCP service to AHP client tools or SDK MCP servers. Avoid copying the extension's in-process HTTP/lock-file details unless the SDK requires that transport for a specific class of tools.

### P1: Built-in VS Code client tool parity is incomplete

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/tools/index.ts` registers `get_vscode_info`, `get_selection`, `open_diff`, `close_diff`, `get_diagnostics`, and `update_session_name`.
- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/tools/push/selectionChanged.ts` and `diagnosticsChanged.ts` provide push-style updates.
- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/diffState.ts` and `readonlyContentProvider.ts` support the extension's diff tools.

**Agent Host state:**

- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts` has a generic client-tool path controlled by `chat.agentHost.clientTools`, with `toolDataToDefinition`, `_beginClientToolInvocation`, and `_tryInvokeClientTool`.
- That generic path exposes allowlisted workbench tools, but I did not find exact equivalents for the extension's built-in CLI MCP tool set, especially diagnostics, current selection, VS Code info, open/close diff, session rename, or push notifications.

**Why it matters:** Diagnostics and selection are high-value local-context tools; diff open/close and session rename are polish but visible. The generic client-tool path is the right abstraction, but the agent likely needs a default curated tool set for selfhosting rather than relying on user configuration.

**Likely direction:** Add default Agent Host client tools for diagnostics, active selection, VS Code/session info, and possibly diff/session-title operations. Keep these as client tools over AHP rather than extension MCP HTTP tools so remote Agent Hosts can consume them too.

### P1: Direct hook customization sync from VS Code files is incomplete

**Extension reference:**

- The extension passes hooks through SDK session options in `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSessionService.ts` `createSessionsOptions`.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCliBridgeSpanProcessor.ts` also enriches hook spans for debugging.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotPluginConverters.ts` can convert parsed plugin hooks into SDK hooks.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts` explicitly omits `PromptsType.hook` because bundling hooks requires merging into `hooks/hooks.json` and is deferred to a follow-up.

**Why it matters:** If the user selects hooks as VS Code customizations, those hooks will not be included in the synthetic plugin bundle sent to the Agent Host. Plugin-directory hooks may work, but direct hook customization files are a gap. Hooks can be important for selfhosting guardrails, test commands, and repo-specific automation.

**Likely direction:** Teach `SyncedCustomizationBundler` to merge hook customization files into the Open Plugin hook layout, then rely on the existing `toSdkHooks` conversion in the Agent Host process.

### P1: Debug/request logging and SDK span bridge parity is partial

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSessionService.ts` configures SDK OTel env, starts debug file logging, and installs `CopilotCliBridgeSpanProcessor` after session creation.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` wraps each request in request logging / OTel spans, logs conversations, logs tool calls, and propagates trace context into the SDK.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCliBridgeSpanProcessor.ts` remaps SDK-native spans into VS Code's OTel/debug stream and enriches hook spans.

**Agent Host state:**

- `src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` has extensive trace logging through `_subscribeForLogging`, including hook, skill, subagent, tool, usage, and session lifecycle events.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/loggingAgentConnection.ts` logs AHP traffic.
- I did not find an equivalent request logger, conversation capture, SDK OTel span bridge, or hook span enrichment.

**Why it matters:** Selfhosting needs diagnosability. AHP traffic logs and provider logs help, but debugging model/tool behavior is much harder without request/response capture and SDK span correlation.

**Likely direction:** Add a provider-side or AHP-side debug stream that can correlate a chat turn, SDK events/spans, tool calls, permissions, and hook execution. Avoid exposing sensitive content unless gated by the same debug/content-capture policy as the extension path.

## Other relevant gaps

### P1/P2: Image attachment and binary content parity

This overlaps with prompt/reference resolution, but it is worth tracking separately. The extension stores image attachments as trusted files via `CopilotCLIImageSupport`, while Agent Host has protocol types capable of embedded/binary content but currently only converts file/directory/selection variables in `_convertVariablesToAttachments`. If image input is expected for Copilot CLI models that advertise vision support, this is P1; otherwise P2.

### P2: Todo list integration from SDK SQL/todo tools

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCLITodoWorker.ts`, `todoSqlQuery.ts`, and `common/copilotCLITools.ts` parse todo updates and invoke `manage_todo_list`.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` watches completed SQL tool calls that modify `todos` / `todo_deps` and updates the todo list widget.

**Agent Host state:**

- I did not find an Agent Host equivalent. `copilotToolDisplay.ts` also lacks explicit display handling for `update_todo` / todo SQL.

**Why it matters:** Useful progress UI, but not required for the agent to edit or ship code. If adopted, it should be represented as protocol state or a client tool, not extension-local SQL scraping.

### P2: External Copilot CLI session discovery and file watching

**Extension reference:**

- `CopilotCLISessionService.monitorSessionFiles` watches `~/.copilot/session-state/**/*.jsonl` and refreshes session lists when external CLI sessions appear/change/delete.
- `shouldShowSession` filters by VS Code origin metadata, workspace tracking, workspace folders, and worktree metadata, with a setting to show external sessions.

**Agent Host state:**

- `CopilotAgent.listSessions` intentionally filters to sessions with an Agent Host database, which keeps it coexisting cleanly with the extension provider.

**Why it matters:** Probably not critical for selfhosting if Agent Host owns its sessions. It becomes relevant only if Agent Host should adopt sessions created by the terminal CLI or the extension-host provider.

### P2: Custom title generation and title metadata richness

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/customSessionTitleServiceImpl.ts` can generate/store custom session titles.
- `CopilotCLISessionService.getSessionTitleImpl` prefers custom titles, pending prompts, SDK title changes, summaries, and first user message fallback.

**Agent Host state:**

- `src/vs/platform/agentHost/node/agentSideEffects.ts` sets and persists titles from session state/actions.
- There is no obvious AI-generated title service or the same first-user-message fallback chain.

**Why it matters:** Mostly session list polish. Not a blocker unless untitled sessions are hard to distinguish during long selfhosting runs.

### P2: Fleet mode and Mission Control `/remote`

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` implements `/fleet` and `/remote`, including Mission Control event export and command polling.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/missionControlApiClient.ts` handles the Mission Control API calls.

**Agent Host state:**

- Agent Host has remote AHP sessions over WebSocket/SSH/tunnels, but I did not find the extension's Mission Control event export/command polling model.

**Why it matters:** Probably not on the VS Code selfhosting critical path unless Mission Control remote steering remains a product requirement for Copilot CLI sessions. It is conceptually separate from Agent Host remote providers.

### P2/P3: Multi-chat grouping under one Copilot session

**Extension reference:**

- `src/vs/sessions/contrib/copilotChatSessions/browser/copilotChatSessionsProvider.ts` supports multiple chats in one logical Copilot session, grouped via `sessionParentId` metadata.

**Agent Host state:**

- `src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts` advertises `supportsMultipleChats: false`; `addChat` / `sendRequest` are not supported in the same way.

**Why it matters:** This is visible parity, but one backend session per chat is simpler and more aligned with the AHP model. Treat as P3 unless product explicitly requires extension-style grouped chats.

### P3: Extension MCP HTTP server and lock-file transport details

**Extension reference:**

- `extensions/copilot/src/extension/chatSessions/copilotcli/vscode-node/inProcHttpServer.ts` and `lockFile.ts` expose VS Code tools to the SDK over MCP HTTP and lock files.

**Agent Host state:**

- Agent Host already has AHP connections, resource operations, terminal operations, and generic client tools.

**Why it matters:** This is mostly an extension-host transport solution. Agent Host should copy the capability where needed, not the HTTP/lock-file transport, unless the SDK requires that exact mechanism for a tool class.

## Important non-gaps already covered by Agent Host

- Core Copilot session lifecycle: `CopilotAgent.createSession`, `listSessions`, `_resumeSession`, `disposeSession`, `abortSession`, `truncateSession`.
- Model selection and thinking level: `_listModels`, `_createThinkingLevelConfigSchema`, `changeModel`, and session-provider model routing.
- Worktree/folder isolation picker and branch completions: `resolveSessionConfig`, `sessionConfigCompletions`, and `BaseAgentHostSessionsProvider` dynamic config.
- Permission levels and edit previews: `resolveSessionConfig` `autoApprove`, `AgentSideEffects` auto-approval, `CopilotAgentSession.handlePermissionRequest`, and pending edit content.
- Session-state auto-approval for `~/.copilot/session-state/<sessionId>/`: `CopilotAgentSession._getInternalSessionResourcePath`.
- Terminal-backed shell tools: `copilotShellTools.ts` `ShellManager` and `createShellTools`, including shell history suppression.
- Generic client tools: `AgentHostSessionHandler` active-client tool definitions and tool result plumbing.
- Steering / queued messages / server-initiated turns: `CopilotAgent.setPendingMessages`, `CopilotAgentSession.sendSteering`, and `AgentHostSessionHandler` pending-message synchronization.
- Subagent rendering/event routing: `CopilotAgentSession._subscribeToEvents`, `copilotToolDisplay.ts` `getSubagentMetadata`, `agentSideEffects.ts`, and `chatSubagentContentPart.ts`.
- File edits and diff rendering: `FileEditTracker`, pending edit content, `AgentHostEditingSession`, and sessions-provider diff handling.
- Local/remote sessions providers: `BaseAgentHostSessionsProvider`, `LocalAgentHostSessionsProvider`, and `RemoteAgentHostSessionsProvider`.

## Suggested critical-path order

1. Fix selection attachment payloads, then port enough prompt/reference resolution for diagnostics, images, PR/merge refs, ignored files, and worktree path translation.
2. Add worktree turn-end commit/checkpoint lifecycle so Agent Host sessions can produce shippable branches.
3. Add PR/shipping flow parity: structured PR URL capture, command/tool display for PR creation, and a first-class ship/apply path for worktree sessions.
4. Add plan exit handling and plan artifacts so plan mode can safely transition into execution.
5. Add MCP gateway/GitHub MCP parity and default client tools for diagnostics/selection/VS Code info.
6. Add hook bundling for direct VS Code hook customization files.
7. Improve debug/request logging and SDK span correlation.
8. Consider todo UI, external-session adoption, title generation, fleet/Mission Control, and multi-chat grouping only after the core loop is solid.