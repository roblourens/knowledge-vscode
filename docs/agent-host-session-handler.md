# Agent Host Session Handler

_Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionListController.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionWorkingDirectoryResolver.ts_

`AgentHostSessionHandler` is the **shared** adapter between AHP session state (see [agent-host-protocol](./agent-host-protocol.md)) and VS Code chat sessions. The same handler runs in all three deployment configurations — VS Code with a local agent host, the Agents app with a local agent host, and the Agents app with one or more remote agent hosts. For the topology and what `connectionAuthority` / `sessionType` mean, see [agent-host-topology](./agent-host-topology.md).

## What it owns

For each chat session backed by an Agent Host, the handler:

- **Creates and subscribes** to the backend session (via `IAgentConnection`). The chat resource's raw path is already the backend raw session id; the handler derives the canonical AHP session URI (`AgentSession.uri(provider, rawId)`, e.g. `copilot:/<rawId>`) and passes it as `createSession({ session, …, activeClient })`. Session creation now passes the active client atomically instead of dispatching a separate `ActiveClientChanged` after the session is created.
- **Converts chat requests into `session/turnStarted`** dispatches.
- **Renders state into chat history and progress** by adapting `ISessionState` updates into chat content parts and progress messages.
- **Handles active-turn reconnection** — if the workbench reattaches mid-turn (after reload, host change, or network blip), the handler resumes rendering from the protocol's replay/snapshot.
- **Handles server-initiated turns** — turns the agent starts on its own, not in response to a user message.
- **Dispatches cancellations** back through the protocol.
- **Renders permission prompts** (tool/file approvals) as VS Code permission UI and forwards the user's choice back as an action. When the server includes `ConfirmationOption[]` on a confirmation action/state, the handler surfaces those choices (e.g. "Allow Once" / "Allow in this Session") instead of plain approve/deny and echoes back `selectedOptionId` on the answer.
- **Hosts client tools** — tools the workbench provides to the session (allowlist controlled via `chat.agentHost.clientTools`); see `agentHostClientTools.ts`.
- **Coordinates file edits** through `AgentHostEditingSession` (`agentHostEditingSession.ts`), which adapts AHP file-edit content into chat editing/checkpoint behavior and uses the Agent Host filesystem connection to read/write snapshots.
- **Coordinates terminals** via terminal state subscriptions and terminal actions on the connection.
- **Coordinates subagents** that the session spawns.
- **Routes per-chat conversation** now that a session is a [container of chats](./agent-host-protocol.md#multi-chat-sessions). The conversation (turns, tool calls, streaming) lives on the **chat** channel; the handler subscribes to the relevant `ChatState`(s), and the list controller / providers aggregate the chat catalog into the single `SessionSummary` a list row shows.
- **Retries on auth-required errors** by calling `authenticate` on the connection (using protected resources advertised in `IRootState`) and re-dispatching.
- **Forwards customization refs** so the active client's customizations apply to the running session.
- **Supplies chat-input completions** by asking the connection for generated AHP completion items, translating command/skill/attachment-backed items into the workbench completion model, and honoring trigger characters announced during initialize.
- **Renders agent-originated input requests** from `SessionState.inputRequests`, including elicitation forms and URL-style affordances that providers translate into the generic AHP input-request state.

## What it does NOT own

- Choosing models — that's `AgentHostLanguageModelProvider` (`agentHostLanguageModelProvider.ts`).
- Discovering agents and registering chat session contributions — that's `AgentHostContribution` (`agentHostChatContribution.ts`), which listens to local `rootState.agents` and dynamically registers one chat session type per advertised agent (`agent-host-${agent.provider}`).
- Listing sessions in the workbench chat list — that's `AgentHostSessionListController` (`agentHostSessionListController.ts`). It fetches sessions via `connection.listSessions()` on the first `refresh()`, caches the result in `_items`, and skips the RPC on subsequent `refresh()` calls. The in-memory cache is kept current by `notify/sessionAdded`, `notify/sessionRemoved`, and `notify/sessionSummaryChanged` notifications. The cache is invalidated (a) implicitly, when the agent registration is torn down and a new controller is created; (b) explicitly, via `resetCache()` called from `AgentHostContribution.onAgentHostStart`, which fires when the agent host process restarts without changing the registration. AHP notifications are not replayed on reconnect, so the explicit path is required. The controller also implements `newChatSessionItem` for local agent-host chat-session startup; see [Chat-session URI ownership](#chat-session-uri-ownership).
- Showing sessions in the Sessions app — that's the `*AgentHostSessionsProvider` family under `src/vs/sessions/contrib/`; see [agent-host-sessions-providers](./agent-host-sessions-providers.md).

## Local vs. remote

The handler is connection-agnostic: it works against `IAgentConnection`, which both the local and remote implementations satisfy. The same `AgentHostSessionHandler` class is constructed with a config like:

```typescript
interface IAgentHostSessionHandlerConfig {
    readonly provider: AgentProvider;     // e.g. 'copilotcli'
    readonly agentId: string;
    readonly sessionType: string;          // identifies (host × agent) in chat sessions
    readonly fullName: string;
    readonly description: string;
    readonly connection: IAgentConnection; // local MessagePort | remote WS/SSH/tunnel
    readonly connectionAuthority: string;  // 'local' | sanitized remote name
}
```

Local wiring is in `agentHostChatContribution.ts` (`AgentHostContribution`); remote wiring is in `src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteAgentHost.contribution.ts` (`RemoteAgentHostContribution`). They differ only in how `sessionType`, `connectionAuthority`, and `connection` are derived.

Lifecycle controls that are local-only (restart, dev-mode startup) live on `IAgentHostService`, not on the handler. If the handler reaches for `IAgentHostService` instead of `IAgentConnection` for a behavior that should also work remotely, that's a bug.

## Chat-session URI ownership

Agent Host chat sessions should not expose `/untitled-*` resources past the generic chat-service staging layer. The raw id in an Agent Host chat resource is the raw backend session id from the moment the resource is handed to `AgentHostSessionHandler`.

There are two creation paths, both client-owned:

- **Sessions app / provider-created drafts.** `BaseAgentHostSessionsProvider.createNewSession(...)` creates an `ISession.resource` with the host-specific chat resource scheme (`agent-host-${provider}` locally, `remote-${authority}-${provider}` remotely) and a final-looking random path (`/${uuid}`). It also records that the resource is still a local draft (`SessionStatus.Untitled`) until the first turn creates the backend session and the backend list reports it.
- **Workbench contributed-chat blank widget.** The chat layer may temporarily create an internal `/untitled-*` resource for a blank contributed chat widget. On first send, `ChatServiceImpl.sendRequest` calls `IChatSessionsService.createNewChatSessionItem(...)` before invoking the agent. For local Agent Host, `AgentHostSessionListController.newChatSessionItem(...)` returns a real final-looking `agent-host-${provider}:/${uuid}` item and marks the raw id as pending-new. The handler is then loaded for that real resource, not for the `/untitled-*` staging URI.

`AgentHostSessionHandler` therefore rejects `agent-host-*:/untitled-*` resources. If one reaches the handler, it means the startup path skipped `newChatSessionItem` or a caller invented a resource outside the Agent Host owner boundary.

For final-looking resources, the handler distinguishes "new draft" from "existing backend session" via explicit ownership predicates, not by path shape:

- Local workbench chat: `AgentHostContribution` wires `AgentHostSessionListController.isNewSession(resource)` into the handler config. That predicate is true only for ids returned by `newChatSessionItem` and is cleared when `notify/sessionAdded`, `notify/sessionRemoved`, or a later `refresh()` observes the real backend session.
- Sessions app providers: `IAgentHostSessionWorkingDirectoryResolver.registerResolver(...)` accepts an `isNewSession` predicate. Local and remote provider contributions register that predicate against the **chat resource scheme** (not the logical provider id) and return true while `getSessionByResource(resource)?.status` is `SessionStatus.Untitled`.

When the first request arrives for a draft, `_createAndSubscribe` derives `requestedSession = AgentSession.uri(config.provider, rawId)` from the chat resource and passes it to `connection.createSession({ session: requestedSession, ... })`. The server/remote connection must return the same URI; a mismatch is a contract error. Forks are the exception: fork creation lets the backend choose the new fork URI because the fork source/turn is the defining input.

## Editing through the handler vs. directly

Code that *runs a turn* belongs in the handler. Code that *changes how a turn is displayed* belongs in the handler's adapter helpers (e.g., `stateToProgressAdapter.ts`). Code that *changes the protocol contract* belongs in [agent-host-protocol](./agent-host-protocol.md), not here.

If a behavior could be expressed as a protocol action and reducer change, prefer that — handler-only state tends to drift across local/remote and across multi-client scenarios.

`stateToProgressAdapter.ts` also marks tool invocations as `presentation: Hidden` when the result carries file edits, so the edit pills rendered through `AgentHostEditingSession` aren't duplicated by the generic tool-call widget. If you add a new tool kind that produces edits, route the edit rendering through the editing session and keep the tool widget hidden the same way.

## Request context and client-tool parity

`AgentHostSessionHandler` converts incoming chat request variables to provider attachments in `_convertVariablesToAttachments`. Today that conversion handles basic files, directories, and implicit selection variables. The `IAgentAttachment` type already supports selection text and range, and the Copilot provider forwards those fields to the SDK when present, but the handler currently sends only the selected file path/display name for selections. Richer prompt/reference parity with the extension-host Copilot CLI still needs explicit work here.

The extension-host Copilot CLI has a dedicated prompt resolver (`copilotcliPromptResolver.ts`) that handles more reference kinds: selected text/ranges, diagnostics, prompt files, GitHub PR references, merge-change references, images, ignore filtering, notebook exclusions, and worktree path translation. Agent Host should port the relevant semantics into AHP-friendly attachments or client tools rather than copying the extension's storage/transport details directly.

Client tools are already generic: `_dispatchActiveClient` sends the active client's tool definitions over AHP, and `_beginClientToolInvocation` / `_tryInvokeClientTool` route tool calls back to VS Code. That is the right abstraction for remote/local parity. The current gap is product defaults and exact Copilot CLI parity: the extension-host path ships built-in VS Code tools such as `get_selection`, `get_diagnostics`, `get_vscode_info`, `open_diff`, `close_diff`, and `update_session_name`, while Agent Host currently relies on the `chat.agentHost.clientTools` allowlist and whatever workbench tools are configured.

## Patterns and gotchas

- **Active-turn reconnect** is the most subtle behavior. If you change how a turn renders, exercise reload-during-turn paths in tests under `agentHostChatContribution.test.ts`.
- **The same handler instance does not span sessions.** Per-session state lives on the handler instance for that session.
- **Disposables register at construction time.** Use `this._register(...)` for normal cleanup. The one deliberate exception in this file is `AgentHostChatSession.dispose()`, which fires `onWillDispose` before the registered disposables are torn down so `ContributedChatSessionData` can evict the session from chat-session caches before the emitter itself is disposed.
- **Preserve the `IAgentConnection` abstraction.** Reach for `IAgentHostService` only when you need a local-lifecycle API (restart, etc.).
- **Customization refs flow through the protocol.** Don't piggyback on workbench-side state to communicate customization changes to the server; use `ISessionActiveClient` and customization actions.
- **A failed first subscription is recoverable.** `_createAndSubscribe` retries the Agent Host session subscription after transient subscription failure before treating the chat session as lost; keep that recovery path paired with transport reconnect behavior rather than converting it into a terminal render error.
- **Handler dispose settles in-flight turns.** `AgentHostSessionHandler.dispose()` is a manual override that disposes every entry in `_activeSessions` and clears the subscription maps before `super.dispose()`. It first calls `_settleInFlightSessions()`, which `complete()`s any session whose `isCompleteObs` is still `false`. This matters for remote reconnects: when a network change gives the host a new `clientId`, the remote contribution tears down this handler and stands up a fresh one. Without settling, the in-flight turn's observers (which read from the now-dead connection subscription) never see completion, the contributed session stays `isCompleteObs === false`, and the backing `ChatModel` is kept alive in the background by `ChatModel#requestInProgressKeepAlive` — so reopening the session reuses the stale model instead of re-resolving fresh content through `provideChatSessionContent`.

## Remote file links in tool messages

`stateToProgressAdapter.ts` rewrites markdown links inside tool `invocationMessage` / `pastTenseMessage` (and other markdown-typed `StringOrMarkdown` fields) so that `file://` links coming back from a **remote** agent host are wrapped through `toAgentHostUri(connectionAuthority, ...)` into the `vscode-agent-host://<authority>/<scheme>/<authority|->/<path>` form (`AGENT_HOST_SCHEME` from `src/vs/platform/agentHost/common/agentHostUri.ts`). This is what lets the workbench resolve those URIs against the right Agent Host filesystem on click.

The rewrite **deliberately empties the link text** (`[label](url)` → `[](newUrl)`). Empty-text `<a>` tags are picked up by `renderFileWidgets` in `chatInlineAnchorWidget.ts` and replaced with `InlineAnchorWidget` (the rich file chip). Preserving the original label would suppress that conversion.

Two coupling points to know about:

1. **The sanitizer must allow the scheme.** `ChatContentMarkdownRenderer` augments the markdown sanitizer's `allowedLinkSchemes` with `AGENT_HOST_SCHEME`. Without that, DOMPurify strips the disallowed `href` *before* `rewriteRenderedLinks` runs, then `rewriteRenderedLinks` sees an `<a>` with no `href` and no text and removes the element entirely — `renderFileWidgets` then has nothing to convert and the message renders as bare "Read " (or just the prefix text, with nothing where the link should be).
2. **The Copilot tool-display side must produce a markdown link with a label** (`[basename](file:///path)`, via `formatPathAsMarkdownLink` in `copilotToolDisplay.ts`). The rewrite is what turns that into the empty-text agent-host form; if the producer ships an empty-text link to begin with, the marked tokeniser may not produce an `<a>` at all.

If you introduce another markdown-typed channel that may carry remote file links (e.g. a new `StringOrMarkdown` field on a state component), route it through `rewriteMarkdownLinks` / `stringOrMarkdownToString` *and* make sure whichever renderer it ends up in also augments `allowedLinkSchemes` with `AGENT_HOST_SCHEME`.

There is **one client-side exception** to the empty-link-text rule, for skill files. When `rewriteLinkTokenRaw` detects a basename of `SKILL.md` (case-insensitive, via `isSkillFileUri`), it tags the rewritten URI with `?vscodeLinkType=skill` AND preserves the original link text (which carries the human-readable skill name from the agent host — e.g. `[plan](file:///.../SKILL.md)`). The chat inline anchor widget keys off the `vscodeLinkType` query parameter to render a rich skill pill labelled with the skill name, instead of the generic file pill that empty-text links produce. The detection lives client-side rather than at the agent host so it stays out of the protocol — no agent-host-specific link metadata leaks into AHP. Link labels destined for this path must be escaped with `escapeMarkdownLinkLabel` (only `\` and `]`), not `escapeMarkdownSyntaxTokens`, since the pill renderer extracts the link text without re-parsing markdown — see [copilot-sdk-tool-display#debt--gotchas](./copilot-sdk-tool-display.md#debt--gotchas).

## Subagent rendering

The subagent flow has a few non-obvious orderings between events that arrive on the parent's stream and events that belong to a child session. The bookkeeping lives in `agentSideEffects.ts` (event routing) and `chatSubagentContentPart.ts` (UI updates).

- **Inner `tool_start` may arrive before `subagent_started`.** When the parent emits the wrapping `task` tool start, the SDK can immediately emit inner tool starts for the child session before the corresponding `subagent_started` action has created the child session in state. These events are buffered in `_pendingSubagentEvents` keyed by the parent tool call id, then drained onto the new session as soon as `subagent_started` lands.
- **`_toolCallAgents` registration must be deferred for inner tool starts.** A `tool_start` carrying a `parentToolCallId` is *for the child session*, but the later `tool_ready` does not carry `parentToolCallId`. If you register the inner tool against the parent in `_toolCallAgents` at start time, `tool_ready` will route the result to the wrong session. Defer registration until drain.
- **Parent may complete without ever emitting `subagent_started`.** If the SDK errors out or the child never starts, `completeSubagentSession` must clear `_pendingSubagentEvents` for that parent tool call id — otherwise the buffer grows unbounded across turns.
- **`subagent_started` arrives after the description is set.** The wrapping tool's `description` is set at `tool_start` time; the agent name only arrives via `subagent_started` later. The `chatSubagentContentPart.ts` autorun must update `description` and `agentName` *independently*, each gated on whether the field actually changed. Gating both updates on a single `_isDefaultDescription` flag (or similar) silently drops the late `agentName` and the UI falls back to the generic "subAgent" label.
- **SDK-specific arg shapes belong in the per-SDK adapter.** The Copilot SDK's `task` tool destructures `agent_type` (snake_case) — that parsing lives in `copilot/copilotToolDisplay.ts::getSubagentMetadata`, not in the generic `agentEventMapper.ts`. The mapper only forwards normalized `subagentAgentName` and `subagentDescription` event fields. See [copilot-agent-provider](./copilot-agent-provider.md).
- **Auto-approval covers tool calls inside subagent sessions.** Tools that should auto-approve in the parent (workspace reads, etc.) must also auto-approve when run by the child. Verify with the protocol integration test that exercises the `subagent` prompt.

## Per-turn model rendering

Restored chat sessions show a per-response model footer when the response history item carries `details: <displayName>`. The handler builds a `TurnModelLookup` (`_createTurnModelLookup`) that resolves per-turn raw model ids — preferring `Turn.usage?.model` / `ActiveTurn.usage?.model`, falling back to `SessionSummary.model?.id` — into namespaced chat language-model ids and into display names via `ILanguageModelsService.lookupLanguageModel(...).name`. The lookup is passed through `turnsToHistory` (per-turn `request.modelId` and `response.details`) and reused when reconstructing the in-flight turn's placeholder request, so a reload mid-turn shows the same model on the in-progress request as the completed turns above it.

Per-model pricing / multiplier information **is** now propagated from AHP (resolving the earlier debt). It rides `SessionModelInfo._meta` under the well-known `pricing` key, defined by the platform-level `agentModelPricing.ts` (`IAgentModelPricingMeta`, `readAgentModelPricingMeta`, `createPricingMetaFromBilling`, `ICAPIModelBilling`). `AgentHostLanguageModelProvider._createMetadata` reads that slot and maps it onto `ILanguageModelChatMetadata` (`multiplierNumeric` / `pricing`), so agent-host sessions now show the same per-model cost/multiplier badges the extension-host Copilot CLI does. See [agent-host-protocol § Important types](./agent-host-protocol.md).

## Cost and usage aggregation

Per-turn token/cost accounting flows through `UsageInfo` / `UsageInfoMeta` (see [agent-host-protocol](./agent-host-protocol.md)) — cost, Copilot AIU (`totalNanoAiu`), and quota snapshots ride `_meta`, read via `readUsageInfoMeta` / `readAccountQuotaSnapshot`. The handler aggregates **subagent** credits into the parent turn via an `ISettableObservable` accumulator, so a parent turn's reported cost includes the work its subagents did. Cancelled turns **retain** their accrued usage (commit `0f0b5838655`) rather than discarding it. Context-size for the gauge comes from the model's `configSchema` `contextSize` property. The UI surfaces live in `chatContextUsageWidget.ts` / `chatContextUsageDetails.ts`, and the per-subagent cost hover in `chatSubagentContentPart.ts`.

## Where to edit

- Turn rendering, progress, history, cancellation, server-initiated turns, permissions, customization refs → `agentHostSessionHandler.ts`.
- Adapter helpers (state → progress) → `stateToProgressAdapter.ts`.
- File edits / checkpoints → `agentHostEditingSession.ts`.
- Client tools (definition/result conversion, allowlist) → `agentHostClientTools.ts`.
- Auth retry behavior → `agentHostAuth.ts`.

## Tests

See [testing](./testing.md) for the four test layers and when to use each. Tests directly relevant to this handler:

- `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostChatContribution.test.ts` — dynamic registration, session id mapping, create/subscribe, progress rendering, cancellation, errors, permission requests, history, tool rendering, attachments, dynamic discovery, config forwarding, **active-turn reconnect**, server-initiated turns, customizations.
- `agentHostClientTools.test.ts` — tool definition/result conversion, allowlist filtering, active-client tool updates.
- `src/vs/workbench/contrib/chat/test/browser/agentHost/agentHostEditingSession.test.ts` — file edit hydration, undo/redo, snapshots, checkpoint disablement.
- `src/vs/workbench/contrib/chat/test/browser/widget/chatContentParts/chatSubagentContentPart.test.ts` — late metadata updates (description→agent name ordering), lazy expand, current-running-tool title.
- `src/vs/platform/agentHost/test/node/agentSideEffects.test.ts` — subagent event buffering, `_pendingSubagentEvents` cleanup when parent completes without `subagent_started`.

When changing the handler, run the workbench adapter tests *and* the protocol/server tests for the underlying behavior — the handler often surfaces server-side bugs.

## Related

- [agent-host-topology](./agent-host-topology.md) — the two-app topology and three deployment configurations the handler runs in.
- [agent-host-protocol](./agent-host-protocol.md) — the contract this handler consumes and dispatches against.
- [agent-host-sessions-providers](./agent-host-sessions-providers.md) — the other consumer of the same `StateComponents.Session` subscriptions, in the Sessions app.

## Debt & gotchas

- **gotcha** (2026-04-30, agentHostSessionHandler.ts:provideChatSessionContent + AgentHostSessionListController.newChatSessionItem) — Agent Host chat resources reaching the handler must be final-looking resources created by the Agent Host owner path. `/untitled-*` is only an internal contributed-chat staging URI; first send must call `IChatSessionsService.createNewChatSessionItem`, which lets `AgentHostSessionListController.newChatSessionItem` choose the real URI. If `agent-host-*:/untitled-*` reaches the handler, treat it as a bug, not as a valid draft.
- **gotcha** (2026-04-30, agentHostSessionHandler.ts:_createAndSubscribe) — the VS Code client chooses the AHP session URI for non-fork Agent Host session creation. `_createAndSubscribe` must pass `session: AgentSession.uri(provider, rawId)` and fail if the connection returns a different URI. Do not reintroduce a UI-resource-to-backend-resource map or let the backend silently generate a different id for the same chat resource.

- **debt** (2026-04-21, agentHostSessionHandler.ts:_convertVariablesToAttachments) — selection attachments currently send only path/display name even though `IAgentAttachment` supports `text` and `selection`, and the Copilot provider forwards them to the SDK. Populate selected text/range before treating selection parity as complete.
- **debt** (2026-04-21, agentHostSessionHandler.ts:_convertVariablesToAttachments) — request context parity is much thinner than the extension-host Copilot CLI prompt resolver: diagnostics, image/binary attachments, PR/merge references, ignored-file filtering, notebook exclusions, and worktree path translation need AHP-native equivalents.
- **debt** (2026-04-21, agentHostSessionHandler.ts:_dispatchActiveClient) — client tools are generic and allowlist-driven, but Agent Host does not yet provide a curated default set equivalent to the extension-host CLI's `get_selection`, `get_diagnostics`, `get_vscode_info`, `open_diff`, `close_diff`, and `update_session_name` tools.
- **RESOLVED** (was debt 2026-05-02, now fixed as of 2026-06-25 / 09c18fe5c5) — `SessionModelInfo` carrying no multiplier/pricing field. Pricing now rides `SessionModelInfo._meta` under the `pricing` key via the platform-level `agentModelPricing.ts`, and `AgentHostLanguageModelProvider._createMetadata` maps it onto `ILanguageModelChatMetadata.multiplierNumeric` / `pricing`. See the "Cost and usage aggregation" section above.

- **gotcha** (2026-04-19, stateToProgressAdapter.ts:rewriteMarkdownLinks + chatContentMarkdownRenderer.ts) — the remote-file link rewrite produces empty-text `<a href="vscode-agent-host://...">` tags on purpose so `renderFileWidgets` can replace them with `InlineAnchorWidget`. This works only if the chat markdown sanitizer augments `allowedLinkSchemes` with `AGENT_HOST_SCHEME`. Drop the scheme from the allowlist (or change the rewrite to keep link text) and the link silently disappears: DOMPurify strips the `href`, `rewriteRenderedLinks` removes the empty `<a>`, and the message renders as bare prefix text. If you add another markdown-typed channel that may carry remote file links, you have to update both sides — see "Remote file links in tool messages" above.
- **gotcha** (2026-04-25, stateToProgressAdapter.ts:rewriteLinkTokenRaw + isSkillFileUri) — SKILL.md files are the documented exception to the empty-link-text rewrite: the basename detection and `?vscodeLinkType=skill` tagging both live client-side, on purpose, so the agent host protocol stays free of VS Code-specific link metadata. If you add a similar "render this kind of link as a rich pill" recognizer (e.g. for prompts, agents, or other instruction files), do it the same way: detect on the client, tag the URI, escape the preserved label with `escapeMarkdownLinkLabel` (NOT `escapeMarkdownSyntaxTokens`).
- **gotcha** (2026-04-19, agentSideEffects.ts:_pendingSubagentEvents) — Inner subagent `tool_start` can arrive before `subagent_started`. Buffer keyed by parent tool call id; clear on both drain *and* `completeSubagentSession` (parent may complete without ever starting the child).
- **gotcha** (2026-04-19, agentSideEffects.ts:_toolCallAgents) — Don't register inner tool starts (those carrying `parentToolCallId`) in `_toolCallAgents` until drain. The matching `tool_ready` lacks `parentToolCallId` and would route to the wrong session.
- **gotcha** (2026-04-19, chatSubagentContentPart.ts) — Update `description` and `agentName` independently in the autorun. Gating both on a single flag drops the late agent name and the UI falls back to "subAgent".
- **gotcha** (2026-04-25, agentHostSessionListController.ts:_cacheValid + agentHostChatContribution.ts:onAgentHostStart) — AHP notifications (`notify/sessionAdded`, `notify/sessionRemoved`, `notify/sessionSummaryChanged`) are **not** replayed on reconnect. `AgentHostSessionListController` uses those notifications to keep its `_cacheValid` in-memory list current. If the agent host process restarts without tearing down the agent registration, the same controller survives with `_cacheValid = true` — but no replay arrives, so the list is stale. `AgentHostContribution` calls `resetCache()` on all tracked controllers via its `onAgentHostStart` listener to handle this case. If you ever move the list cache to a longer-lived object outside the controller instance, you must preserve both invalidation paths: (a) implicit reset on registration teardown; (b) explicit reset on `onAgentHostStart`.
- **gotcha** (2026-04-21, agentHostSessionHandler.ts:AgentHostChatSession.dispose) — `onWillDispose` must fire before `super.dispose()`. Firing it through `this._register(toDisposable(...))` runs too late because registered disposables are already being disposed; listeners like `ContributedChatSessionData` then miss the chance to evict the session before later lookups and messages can route to stale state.
- **gotcha** (2026-06-27, agentHostSessionHandler.ts:AgentHostSessionHandler.dispose + _settleInFlightSessions) — the handler's `dispose()` is a **manual override** (not just `this._register` cleanup): it iterates `_activeSessions`, disposes each `AgentHostChatSession`, and clears the subscription maps before `super.dispose()`. Two consequences a future change must preserve: (1) anything that must run against the active sessions on teardown has to be done **inside this override**, before the dispose loop — a `this._register(toDisposable(...))` runs during `super.dispose()`, i.e. *after* `_activeSessions` has been cleared, so it sees an empty map. (2) Disposing an `AgentHostChatSession` does **not** complete the in-flight `ChatModel` request; completion is driven by the contributed-session progress autorun in `chatServiceImpl.loadRemoteSession` reacting to `isCompleteObs`. So the override calls `_settleInFlightSessions()` (sets `isCompleteObs = true`) first, otherwise the stale background model stays "in progress" and is kept alive by `ChatModel#requestInProgressKeepAlive` (the remote `clientId`-change reconnect bug, #318604).

## Changelog

- **2026-06-27** — 5edb399a83 — `AgentHostSessionHandler.dispose()` now calls `_settleInFlightSessions()` before tearing down `_activeSessions`, completing any session whose turn is still in flight. Fixes a remote reconnect bug (#318604) where a `clientId` change disposed the handler, the in-flight turn never completed, and `ChatModel#requestInProgressKeepAlive` kept the stale background model alive so reopening reused it instead of re-resolving through `provideChatSessionContent`. Added a "Patterns and gotchas" body bullet and a gotcha on the manual `dispose()` override (registered disposables run after `_activeSessions` is cleared; disposing a session does not complete its ChatModel request).

- **2026-06-25** — 09c18fe5c5 — reconciliation: **resolved** the 2026-05-02 `SessionModelInfo` pricing/multiplier debt — pricing now rides `SessionModelInfo._meta` under the `pricing` key (`agentModelPricing.ts`), and `AgentHostLanguageModelProvider._createMetadata` maps it onto `ILanguageModelChatMetadata` (updated the "Per-turn model rendering" note and the debt entry). Added a **Cost and usage aggregation** section (`UsageInfo` / `UsageInfoMeta`, subagent-credit `ISettableObservable` accumulator, cancelled turns retain usage per `0f0b5838655`, `chatContextUsageWidget.ts` / `chatContextUsageDetails.ts` / subagent cost hover). Noted that the handler now **routes per-chat conversation** through the chat channel under the multi-chat session model.

- **2026-05-15** — 12443ea83d — reconciliation: documented chat-input completions/slash-command support (`394e46e44cb`, `1fbe0acb198`), input-request/elicitation rendering (`acdf223a800`), failed-subscription recovery (`59f7592b5d1`), generic config-picker integration, and the moved remote contribution path.

- **2026-05-02** — `cb70af8eb9` — added "Per-turn model rendering" section: handler now builds a `TurnModelLookup` (`_createTurnModelLookup` injecting `ILanguageModelsService`) and passes it through `turnsToHistory` so each restored request gets its turn's `usage.model` (falling back to `SessionSummary.model?.id`) and each response carries `details: <displayName>`. Active-turn placeholder request uses the same per-turn fallback. Added debt entry covering missing multiplier/pricing on `SessionModelInfo`.
- **2026-05-01** — b2e6267136 — reconciliation: no body changes. `8dbb8606e2c2` and `21706550d0fd` refined the final-resource / session-type plumbing already captured by the chat-session URI ownership section.
- **2026-04-30** — `928bc0340d` — documented Agent Host chat-session URI ownership: `/untitled-*` is only an internal contributed-chat staging resource, `AgentHostSessionListController.newChatSessionItem` creates the final local URI before first send, provider-created drafts already use final-looking resources, and `AgentHostSessionHandler` derives and requests the canonical AHP URI directly from the chat resource.
- **2026-04-25** — `89433a4490` — documented the SKILL.md client-side exception to the empty-link-text rewrite in "Remote file links in tool messages": `rewriteLinkTokenRaw` detects `SKILL.md` via `isSkillFileUri`, tags the URI with `?vscodeLinkType=skill`, and preserves the link label (the skill name) so the chat inline anchor widget renders a rich skill pill. Detection lives client-side so no VS Code-specific link metadata leaks into AHP.
- **2026-04-25** — `99e59eeecd` — documented `AgentHostSessionListController` caching: first `listSessions()` primes the cache; subsequent `refresh()` calls serve from `_items`; `onAgentHostStart` in `AgentHostContribution` calls `resetCache()` to handle agent host restart without registration teardown (AHP notifications not replayed on reconnect). Added gotcha for both invalidation paths.
- **2026-04-24** — `5407371c47` — reconciliation: noted server-provided `ConfirmationOption[]` rendering on tool-call confirmations (commit `779b23b6196`), the eager `activeClient` parameter on `createSession` replacing the post-create `ActiveClientChanged` round-trip (`886c556841c`), and the `presentation: Hidden` flag on file-edit tool invocations to avoid duplicate edit pills (`e85baae4d67`). PostToolUse hook fix (`59be36b6d53`) and deferred repo-hook loading (`dd1eb813ec4`) are server/sessions-provider-side and don't change the handler's prose.
- **2026-04-21** — `ad531180d0` — added request-context/client-tool parity section and debt entries for selection payloads, prompt/reference/image gaps, and default VS Code client-tool parity.
- **2026-04-21** — `ad531180d0` — reconciliation: documented the `AgentHostChatSession.dispose()` ordering fix from `cf0709667ed`; the merge commit in the same range did not change handler concepts beyond that fix.
- **2026-04-20** — `00f882a16c` — updated the example `provider:` value in the `IAgentHostSessionHandlerConfig` snippet from `'copilot'` to `'copilotcli'` (`CopilotAgent.id` rename).
- **2026-04-19** — `b708764819` — added a "Remote file links in tool messages" section covering `rewriteMarkdownLinks` in `stateToProgressAdapter.ts`, the deliberate empty-text rewrite, and its dependency on `ChatContentMarkdownRenderer` augmenting `allowedLinkSchemes` with `AGENT_HOST_SCHEME`; added a gotcha capturing the silent-failure mode if the two sides drift.
- **2026-04-19** — `2935e7d695` — added "Subagent rendering" section covering buffering, deferred `_toolCallAgents` registration, independent `description`/`agentName` updates in `chatSubagentContentPart.ts`, and parent-without-child cleanup. Cross-linked the new testing doc and added subagent-related test references.
- **2026-04-18** — `96ab46a042` — cross-linked to the new agent-host-sessions-providers doc; clarified that the providers share the same refcounted `StateComponents.Session` subscriptions.
- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the role of `AgentHostSessionHandler` as the shared local/remote adapter between AHP session state and VS Code chat sessions, including turn dispatch, progress rendering, active-turn reconnect, server-initiated turns, permissions, client tools, file edits, terminals, subagents, auth retries, and customization refs. Drawn from the prior `agent-host-chat-sessions` skill.
- **2026-04-16** — `6cd94ddc6f` — added `IAgentHostSessionHandlerConfig` example showing the local-vs-remote seam, and cross-referenced the new topology doc.
