# Agent Host customization item providers

_Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostLocalCustomizations.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentCustomizationItemProvider.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteAgentHostCustomizationHarness.ts, src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteAgentHost.contribution.ts_

The agent-host customization item providers turn an agent host's set of plugin/customization references into the per-file (skill / agent / instructions / prompt) entries that show up in the chat customization view, in the chat input editor's slash-command decorations, and in `resolvePromptSlashCommand` calls. They live alongside (but are distinct from) `AgentHostSessionHandler`'s in-protocol `customization` action forwarding — the handler sends customization *refs* over the wire, while these providers expand a ref into individual user-visible items by reading filesystems.

Display expansion now converges on `AgentCustomizationItemProvider`. Local Agent Host chat registrations instantiate it directly; the remote Sessions contribution wraps the same provider with remote-only remove actions. Local customization enumeration is still separate: `enumerateLocalCustomizationsForHarness` discovers files that should be synced to the host, while `AgentCustomizationItemProvider` expands host/session customization refs that are already present in AHP state.

The inputs still differ by origin:

| Concern | Local synced input | Shared host/session ref expansion |
|---|---|---|
| File source | Local `IPromptsService` index (workspace + user + extensions) **+ built-in skills from `BUILTIN_STORAGE`** | Host-configured plugins from root config + session-synced plugins, walked as direct synced-bundle URIs or `agent-host://` URIs through `IFileService` |
| Skill metadata | `IPromptsService.findAgentSkills(token)` for local sync discovery | `IFileService.readFile(SKILL.md)` + `new PromptFileParser().parse(...)` while expanding a plugin/bundle |
| Item shape | Refs bundled for `activeClient.customizations` | Parent plugin item + expanded children, with `groupKey` for remote-host vs remote-client/synced |
| Change events | `IPromptsService.onDidChange*` | `IAgentConnection.rootState` + `SessionCustomizationsChanged` actions |
| Caching | None — live query each call | `_expansionCache: ResourceMap<{nonce, children}>`, invalidated by nonce change |

These are intentionally adjacent but not interchangeable: local discovery decides what the client syncs, while the shared item provider renders refs the host exposes. The provider also understands synthetic synced bundles: it expands them in-place instead of wrapping them in `agent-host://`, because the bundle filesystem lives on the client. The only piece that is still a reasonable extraction is the SKILL.md frontmatter helper (also independently reimplemented in `AgenticPromptsService.discoverBuiltinSkills`).

## Customization taxonomy

The protocol's `CustomizationType` enum has grown beyond plugins/files. Today it is `Plugin | Directory | Agent | Skill | Prompt | Rule | Hook | McpServer`. There is **no** `SessionCustomization` type — session-scoped customizations are just refs in `activeClient.customizations` / `SessionCustomizationsChanged`. `Plugin` and `Directory` are *container* types whose children are expanded by the item provider; `ClientPluginCustomization` carries a `nonce` for cache invalidation.

`ICustomizationItemProvider` gained a `provideSourceFolders` method so a provider can report the folders backing its customizations (used by features that need the on-disk roots, not just expanded items). Each returned `ICustomizationSourceFolder` now also carries a `source` (`AICustomizationSources.local` vs `.user`), derived the same way item expansion classifies local vs user-level customizations (`workingDirectory`-relative vs not), so folder pickers can group/label source folders consistently with the items they back.

Rule/instruction items now get a finer-grained `groupKey` in addition to the existing `REMOTE_CLIENT_GROUP`: a rule with `globs` gets `'context-instructions'` (with a `badge`/`badgeTooltip` showing the glob pattern, or "always added" for `**`), a rule with `alwaysApply` gets `'agent-instructions'`, and anything else gets `'on-demand-instructions'`. This only applies to non-remote items — `isRemote` (renamed from the old bare `groupKey` parameter threaded through `toDirectoryItems`/`toDirectoryChildItem`) still wins first and assigns `REMOTE_CLIENT_GROUP`.

The standalone `IAgentHostCustomAgentsService` was **removed**; custom-agent handling was consolidated into `AgentCustomizationItemProvider` plus `IAgentHostCustomizationService`. `AgentHostModeSynchronizer` survives as the piece that keeps chat **modes** in sync. **Hooks** (`CustomizationType.Hook`) are deliberately excluded from prompt sync — they are not prompt-attachable customizations.

## MCP servers as customizations

MCP servers are modeled as `CustomizationType.McpServer` — there is **no** dedicated MCP channel. `McpServerCustomization` carries `{ enabled; state: McpServerState; channel?; mcpApp? }`, where `channel?` is an `mcp://` subscription URI. Default UI-host capabilities live in `protocol/mcpAppDefaults.ts` (`DEFAULT_MCP_APP_CAPABILITIES` / `AhpMcpUiHostCapabilities`). On the server side, `McpCustomizationController` (`node/` + shared) reflects the SDK's MCP inventory into customization state.

Syncing the user's VS Code MCP configuration into the host goes through `agentHostLocalCustomizations.ts` plus `syncedCustomizationBundler.ts` (`SyncedCustomizationBundler` / `ISyncableMcpServer`); the host-side server-options surface is reachable via the `workbench.mcp.agentHostServerOptions` command.

## The skill-folder convention

Skills are conventionally a folder named after the skill, containing a `SKILL.md` whose frontmatter holds the canonical `name` and `description`. Both providers must understand this convention, otherwise:

- **Bad name.** `getFriendlyName(basename(file.uri))` on a `SKILL.md` returns `"SKILL"` for every skill. Use the parsed frontmatter `name`, falling back to the parent folder name. (For local: get this from `findAgentSkills`. For remote: read `SKILL.md` and parse with `PromptFileParser`.)
- **Bad URI.** `ICustomizationItem.uri` for a folder-style skill must point at `<folder>/SKILL.md`, **not** the folder itself. Downstream `IChatCustomizationHarnessService.resolvePromptSlashCommand` and `InputEditorDecorations.updateAsyncInputEditorDecorations` call `parseNew(item.uri)`, which is a file read; passing a directory URI throws `EntryIsADirectory` and silently breaks decorations and slash-command resolution.

The remote provider additionally **skips folder-style skill entries whose `SKILL.md` cannot be read** rather than emitting a known-broken URI. The local provider doesn't need this guard because `findAgentSkills` already filters at index time.

Remote hosts have a management action, `RemoteAgentPluginController.addConfiguredPlugin`, that lets the user add a plugin folder already present on the remote host. It opens an `agent-host://` folder picker rooted at the remote filesystem, converts the selected URI back to the host's original URI, and dispatches `RootConfigChanged` with the updated `AgentHostConfigKey.Customizations` array. Host-owned plugin items get a remove action that writes the same root config; client-synced session customizations are still shown as local-group items but are not removable from the remote host config.

## Built-in skills (`BUILTIN_STORAGE`)

The agent window ships a set of built-in slash-command skills (`/create-pr`, `/merge`, `/update-pr`, `/create-draft-pr`) defined as SKILL.md files inside the `extensions/copilot/` extension folder. These are surfaced through `AgenticPromptsService` under the `BUILTIN_STORAGE` sentinel value (defined in `aiCustomizationWorkspaceService.ts`), which is NOT a member of the core `PromptsStorage` enum — it is an extra value recognized only by `AgenticPromptsService` (the agent-window-aware implementation).

`enumerateLocalCustomizationsForHarness` calls `promptsService.listPromptFilesForStorage(PromptsType.skill, BUILTIN_STORAGE as PromptsStorage)` and appends the results so they are included in the synced customization bundle that both local and remote agent hosts see. The built-in entries carry `storage: BUILTIN_STORAGE` and are subject to `syncProvider.isDisabled(uri)` like any other skill.

**Critical:** the regular workbench `PromptsServiceImpl` throws for unknown storage values. Always wrap the `BUILTIN_STORAGE` lookup in `try/catch` and treat any throw as "no built-in skills available" — the implementation only has the built-in skills when `AgenticPromptsService` is active (agent window context). See the `gotcha` entry below.

## `supportsPromptAttachments`

Both AH chat session contributions (local `agentHostChatContribution.ts` and remote `remoteAgentHost.contribution.ts`) declare `supportsPromptAttachments: true` in their `capabilities` block so the chat input wires up prompt attachment UI for AH sessions. This is independent of the providers above but is in the same "make AH skill/prompt UX reach parity" surface area; if you add another AH chat session contribution, set this flag too.

Both harness descriptors also set `hiddenSections` to hide management-UI sections that don't apply to their surface. The local harness (`agentHostChatContribution.ts`) now hides `AICustomizationManagementSection.Prompts` for every provider (previously only non-Copilot-CLI providers hid it) and additionally hides `Tools` for non-Copilot-CLI providers; the remote harness (`remoteAgentHostCustomizationHarness.ts`) hides `Models` and `McpServers`. Both harnesses still implement `getStorageSourceFilter`/`IStorageSourceFilter`; Automations reintroduced that source-filter contract after an intermediate removal.

A new **Automations** feature (scheduled/recurring agent runs, `src/vs/sessions/contrib/automations/`, outside this doc's Covers) reuses `AgentCustomizationItemProvider` and threads permission/model selection through the same `ChatInputPart`/`ChatInputSecondary` menu machinery described in [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md). It is a new consumer, not a change to the provider contract itself.

## Decoration revival on reload

There is a known asymmetry in how chat request decorations (e.g. the skill pill on a sent request) survive a window reload:

- **Local chat sessions.** Requests are persisted as serialized `IParsedChatRequest` parts and revived structurally by `reviveParsedChatRequest`. Whatever parts (including `ChatRequestSlashPromptPart`) were written at send time are restored exactly. There is **no** re-parsing against the current slash-command set.
- **AH chat sessions.** Requests are reconstructed from raw AHP state — the user message text, with no preserved parsed-parts structure. Slash-command decorations are therefore lost across reload, even when the skill is still recognized.

If you need decorations to survive reload for AH sessions, the pragmatic fix is to re-run `ChatRequestParser.parseChatRequest` against the current slash commands when hydrating each AH user message. This would also retroactively pick up skills that became known after the request was originally sent.

## Related

- [agent-host-session-handler](./agent-host-session-handler.md) — the in-protocol customization-ref forwarding (different concern); also home of the SKILL.md client-side link-rewrite gotcha.
- [agent-host-topology](./agent-host-topology.md) — explains why customizations are opaque [Open Plugin](https://open-plugins.com/) refs at the AHP layer.

## Debt & gotchas

- **gotcha** (2026-04-28, agentHostLocalCustomizations.ts + agentCustomizationItemProvider.ts:_collectFromTypeDir) — for folder-style skills, `ICustomizationItem.uri` MUST be `<folder>/SKILL.md`, not the folder URI. Downstream `parseNew(item.uri)` is a file read; a directory URI silently breaks slash-command resolution and chat input decorations. Provider-side expansion skips skills whose `SKILL.md` cannot be read; local sync discovery relies on `IPromptsService.findAgentSkills` to filter.
- **gotcha** (2026-04-28, agentHostLocalCustomizations.ts + agentCustomizationItemProvider.ts) — for skill display name, NEVER use `basename(file.uri)` on a `SKILL.md` — it returns the literal string `"SKILL"`. Use the frontmatter `name` (via `findAgentSkills` for local discovery, `PromptFileParser` for provider expansion) and fall back to the parent folder name.
- **gotcha** (2026-04-29, agentHostLocalCustomizations.ts:enumerateLocalCustomizationsForHarness) — `BUILTIN_STORAGE` is NOT a member of the `PromptsStorage` enum; it is a sentinel recognized only by `AgenticPromptsService`. The regular workbench `PromptsServiceImpl` throws for unknown storage values, not returns `[]`. Always wrap the `listPromptFilesForStorage(..., BUILTIN_STORAGE)` call in `try/catch` and treat any throw as empty. Tests for this function should model the throw, not a silent empty return.
- **debt** (2026-04-28, multiple) — SKILL.md frontmatter parsing is now duplicated in four places: `IPromptsService.findAgentSkills`, `AgentCustomizationItemProvider._readSkillMetadata`, `AgentHostSkillCompletionProvider._readSkillMetadata`, and `AgenticPromptsService.discoverBuiltinSkills`. A shared helper in `promptSyntax/` would consolidate them.
- **debt** (2026-04-28, AH chat session restore path) — AH-restored chat requests don't re-parse for slash commands, so skill decorations don't survive reload. Re-running `ChatRequestParser.parseChatRequest` when hydrating AH user messages from AHP state would fix this.

## Changelog

- **2026-07-02** — f9f2fd558a — reconciliation: documented `provideSourceFolders`' new per-folder `source` (local vs user) field and the new `groupKey`/`badge` classification for Rule items (`context-instructions` / `agent-instructions` / `on-demand-instructions`) added by `ac174e660b1` and `2ec88ac9a42`. Updated the `hiddenSections` description for both harnesses and noted that Automations (`4c959fa6747`) reintroduced the `getStorageSourceFilter`/`IStorageSourceFilter` contract after its intermediate removal in `34fa7dbcc38`. Noted the new **Automations** feature as a consumer of `AgentCustomizationItemProvider`, outside this doc's Covers. The host-side `~/.copilot/skills` user-dir discovery fix (`1ae8d999061`) touches `sessionCustomizationDiscovery.ts`, which is not in this doc's Covers (host-side discovery, not the client-side item providers) — no body change needed for it.

- **2026-06-25** — 09c18fe5c5 — reconciliation: added a **Customization taxonomy** section (`CustomizationType` is now `Plugin | Directory | Agent | Skill | Prompt | Rule | Hook | McpServer`; no `SessionCustomization`; `Plugin`/`Directory` are containers; `ClientPluginCustomization.nonce`; new `ICustomizationItemProvider.provideSourceFolders`; `IAgentHostCustomAgentsService` removed and folded into `AgentCustomizationItemProvider` + `IAgentHostCustomizationService`; `AgentHostModeSynchronizer` survives; Hooks excluded from prompt sync). Added a **MCP servers as customizations** section (`CustomizationType.McpServer`, `McpServerCustomization`, `protocol/mcpAppDefaults.ts`, `McpCustomizationController`, `syncedCustomizationBundler.ts` / `SyncedCustomizationBundler` / `ISyncableMcpServer`, `workbench.mcp.agentHostServerOptions`).

- **2026-05-15** — 12443ea83d — reconciliation: documented the shared `AgentCustomizationItemProvider`, synthetic synced-bundle expansion, and current remote provider paths after `fec57be8249`, `cb855bd361c`, and the Sessions provider move in `a3d955d72ad`.

- **2026-05-04** — 939d3f227c — reconciliation: no body changes. `c30ed7c4a51` added implicit read grants for outgoing customization refs so existing remote plugin sync remains friction-free under filesystem permission gating, and `e1a89568eb2` only touched remote contribution connection-status plumbing.

- **2026-05-01** — b2e6267136 — reconciliation: documented remote host plugin management via `RemoteAgentPluginController` after `e6b9ae7ff17a`; `8dbb8606e2c2` only reinforced the existing final-resource URI contract from the session-handler doc.
- **2026-04-29** — `fa1adf3685` — added "Built-in skills (`BUILTIN_STORAGE`)" section; updated local-AH table row to include built-in skills; added gotcha for `BUILTIN_STORAGE` throw vs empty-return in `PromptsServiceImpl`. PR [#313277](https://github.com/microsoft/vscode/pull/313277).
- **2026-04-28** — `258af94280` — initial entry. Captures the local vs remote split, the SKILL-folder convention (frontmatter for `name`/`description`, SKILL.md URI for `item.uri`, skip unreadable SKILL.md entries), the `supportsPromptAttachments: true` capability flag on both AH chat session contributions, and the decoration-revival asymmetry between locally-persisted and AH-restored chat requests.
