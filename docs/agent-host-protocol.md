# Agent Host Protocol (AHP)

_Covers: src/vs/platform/agentHost/common/state/_

The Agent Host Protocol is the wire contract between an AHP **client** and an AHP **server**. The protocol is deliberately generic: neither side is "VS Code." For why that matters and how the topology shakes out across the VS Code repo's two apps, read [agent-host-topology](./agent-host-topology.md) first.

This doc is about the **contract itself** — state shapes, actions, subscriptions, capabilities, and where to edit them.

The mental model is **JSON-RPC plus immutable state**:

- Clients `initialize` (negotiating capabilities), then subscribe to URI-addressed resources.
- Clients create / list / dispose sessions, dispatch actions, and receive **action envelopes** plus notifications.
- Reconnection works by **replay** (action sequence numbers) or **snapshot**.

## Where it lives

```
src/vs/platform/agentHost/common/state/
├── protocol/                 ← generated surface, DO NOT EDIT
│   │                            source of truth: ../agent-host-protocol repo
│   ├── state.ts              ← re-export glue: `export *` from common/ + every channels-*/
│   ├── actions.ts / commands.ts / reducers.ts / notifications.ts / messages.ts
│   ├── errors.ts             ← AhpErrorCodes + the rich AhpError<C> type machinery
│   ├── common/               ← cross-channel primitives (ActionType, BaseParams, UsageInfo, ...)
│   ├── version/registry.ts   ← PROTOCOL_VERSION, ACTION/NOTIFICATION_INTRODUCED_IN maps
│   ├── mcpAppDefaults.ts     ← DEFAULT_MCP_APP_CAPABILITIES
│   └── channels-*/           ← one dir per subscribable channel (see below)
├── sessionProtocol.ts        ← re-exports the JSON-RPC message/command/error surface
├── sessionState.ts           ← re-exports generated state + VS Code-only `_meta` helpers
├── sessionActions.ts         ← action types dispatched by clients, applied by server
├── sessionReducers.ts        ← reducers, used server-side AND client-side (optimistic)
├── agentSubscription.ts      ← AgentSubscriptionManager — the client read model
├── sessionTransport.ts       ← transport abstractions (MessagePort, WebSocket, ...)
└── AGENTS.md                 ← governing rules for editing this dir
```

The protocol now uses a **channel-based wire model** (`agentHost: adopt channel-based AHP wire model`). The old flat "root state / session state / terminal state" split is now a hierarchy of channels, one directory per subscribable URI scheme, each with its own `state.ts` + `actions.ts` + `reducer.ts` (+ optional `commands.ts` / `notifications.ts`). The top-level `protocol/state.ts` no longer defines `RootState` / `SessionState` / `TerminalState` itself — those live in their owning channel, and `state.ts` is pure re-export glue.

| Channel dir | Owns | Subscribable URI |
|---|---|---|
| `channels-root` | `RootState`: advertised `agents`, `activeSessions?`, `terminals?`, host-level `config?`; `ModelSelection` / `SessionModelInfo` / `PolicyState` | `agenthost:/root` |
| `channels-session` | `SessionState`: session metadata inlined directly (title, status, activity, project, workingDirectory, annotations — see `SessionMetadata`), lifecycle, `chats` catalog + `defaultChat`, `activeClients`, customizations, changesets catalogue, aggregated `inputNeeded`, config | `copilot:/<rawId>` (per provider) |
| `channels-chat` | `ChatState`: per-chat conversation — turns, active turn, tool calls, steering/queued messages, input requests | `ahp-chat:/<uuid>` |
| `channels-terminal` | `TerminalState` / `TerminalInfo` / `TerminalClaim` | terminal URI |
| `channels-changeset` | `Changeset` catalogue + `ChangesetState` (files + invokable operations) | `<sessionUri>/changeset/<id>` |
| `channels-annotations` | `AnnotationsState` — file-anchored conversation/feedback annotations | `<sessionUri>/annotations` |
| `channels-resource-watch` | `ResourceWatchState` — file/dir watchers | `ahp-resource-watch:` URI |
| `channels-otlp` | OpenTelemetry-over-AHP log/trace/metric export | `ahp-otlp:` URI |

When the contract changes, the workflow is: edit the [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) repo first, regenerate the `protocol/` subdir here (`npx tsx scripts/sync-agent-host-protocol.ts`), then update the surrounding shims and the server handler. The governing rules live in `state/AGENTS.md`.

## Resource addressing

State is URI-addressed, one URI per channel instance.

- **Root state:** `agenthost:/root` — advertised agents, models, protected resources, customizations, active session count, terminals, and host-level config (`RootState.config?: RootConfigState`).
- **Session state:** keyed by provider URI such as `copilot:/<rawId>` or `mock:/<rawId>`. Use `AgentSession.uri(provider, rawId)` to construct canonically. A session is now a **container of chats** (see [Multi-chat sessions](#multi-chat-sessions)).
- **Chat state:** keyed by chat URI (`ahp-chat:/<uuid>`). The conversation itself — turns, tool calls, streaming deltas — lives on the chat channel, not the session channel.
- **Terminal state:** keyed by terminal URI. Used by terminal subscriptions.
- **Changeset / annotations state:** nested under the session URI (`<sessionUri>/changeset/<id>`, `<sessionUri>/annotations`). See [agent-host-git-driven-diffs](./agent-host-git-driven-diffs.md) and the annotations note below.

## Subscriptions

`AgentSubscriptionManager` (in `agentSubscription.ts`) gives clients a reactive read model. There are three subscription types:

| Subscription | Class | Optimistic writes? |
|---|---|---|
| Root | `RootStateSubscription` | No |
| Session | `SessionStateSubscription` | **Yes** (write-ahead + reconcile) |
| Terminal | `TerminalStateSubscription` | No |

Session subscriptions are the only ones with optimistic dispatch: a client applies its own action through the local reducer immediately, then reconciles when the server's `IActionEnvelope` echoes back with a sequence number. Root and terminal state are server-confirmed only.

This is the right place to look when reasoning about what state a client sees vs. what the server has applied. Client code should always read state through a subscription — never reach for the server directly.

For observable consumers, `observableFromSubscription(owner, sub)` adapts an `IAgentSubscription<T>` into `IObservable<T | undefined>`. It deliberately maps pre-snapshot and error states to `undefined`; callers that need to surface the actual `Error` should read `sub.value` directly.

## Action envelopes

Every server-applied action is wrapped in an `ActionEnvelope`:

```typescript
interface ActionEnvelope {
    readonly seq: number;        // server-assigned sequence number
    readonly action: StateAction;
    readonly origin?: string;    // tag of the client that dispatched (if any)
}
```

The `seq` drives **replay-based reconnection**: a client that drops and reattaches asks for actions since its last seen `seq`, and the server fills in the gap (or sends a fresh snapshot if the gap is too large). The `origin` lets a client recognize its own optimistic action coming back as confirmed and reconcile it with what the server actually applied (which can differ — e.g. the server may have rejected or transformed it).

Protocol-generated types do **not** carry an `I` prefix. The shapes generated under `state/protocol/` use plain names (`RootState`, `SessionState`, `ActionEnvelope`, `StateAction`, `FileEdit`, `ModelSelection`, …); the `I`-prefixed names from earlier docs no longer exist. Code outside `state/protocol/` may still wrap or re-export these under VS Code-style names, but the wire contract is the bare shape.

## Multi-chat sessions

A session is a **container of chats**, not a single conversation. This is the biggest protocol shift since the channel model: the conversation (turns, tool calls, streaming) lives on the **chat** channel; the **session** channel owns the catalog plus session-wide concerns (config, customizations, changesets, active clients).

- `SessionState.chats: ChatSummary[]` — the catalog of chats in the session.
- `SessionState.defaultChat?: URI` — the chat that receives input when the user addresses the session without picking a specific chat. It is a **UI routing hint, not a hierarchy marker** — chats are equal peers at the protocol level.
- `ChatSummary` — lightweight catalog entry: `resource`, `title`, `status: SessionStatus`, `activity?`, `modifiedAt`, `origin?: ChatOrigin`, `interactivity?: ChatInteractivity`, `workingDirectory?`. It does **not** carry `model` / `agent` — those moved onto `Message` (see below).
- `ChatState` (chat channel) **denormalizes** every `ChatSummary` field inline and adds `turns`, `activeTurn?`, `steeringMessage?`, `queuedMessages?`, `inputRequests?`, `draft?: Message`. Producers MUST keep `ChatState` and the matching `ChatSummary` consistent.
- `ChatOrigin` — how a chat came to exist: `{ kind: User }`, `{ kind: Fork; chat; turnId }`, or `{ kind: Tool; chat; toolCallId }` (the canonical record of a tool-spawned subagent worker).
- `ChatInteractivity` — `Full` (default), `ReadOnly`, `Hidden`; supports the agent-team lead/worker pattern.

**Model/agent selection lives on `Message`, not on session or chat state** (`Agent host: adopt flattened SessionState protocol`). `Message.model?: ModelSelection` and `Message.agent?: AgentSelection` record the model/custom-agent a historic message was actually sent with; on `ChatState.draft` they carry the user's in-progress pick for the message they're composing. There is no more session- or chat-level "current model" field — a session's effective default model is derived from the last turn or draft selection, not stored separately. The `session/modelChanged`, `session/agentChanged`, and `session/activeClientToolsChanged` actions were dropped along with this; don't look for them.

**Chat lifecycle.** Two commands on the chat channel — `createChat` (`CreateChatParams`: `channel` = session URI, `chat` = client-chosen `ahp-chat:/<uuid>`, optional `initialMessage` / `source`) and `disposeChat`. `initialMessage` (a full `Message`) is how a client-selected model/agent for the new chat's first turn is conveyed now that `createChat` no longer takes bare `model`/`agent` params. **Forking** is a `createChat` with `source: ChatForkSource { chat; turnId }` — content up to and including that turn's response is copied into the new chat. Note the split: chat-content actions live on the **chat** channel, but **catalog** mutations live on the **session** channel (`SessionChatAdded` / `SessionChatRemoved` / `SessionChatUpdated` / `SessionDefaultChatChanged`), mirroring the root channel's `sessionAdded` / `sessionRemoved` / `sessionSummaryChanged` one level down. A client that wants multi-chat or fork commands MUST first check `AgentInfo.capabilities?.multipleChats` (and its `fork` sub-flag) — see [Capabilities](#capabilities) below.

**Default-chat compatibility layer** (`agentHost: adopt multi-chat sessions protocol (default-chat compat layer)`). Single-chat-aware clients see a multi-chat session through `SessionSummary` aggregation. Once a session has more than one chat, `SessionSummary` fields are derived from the chat catalog:

- `status` — activity bits from the `defaultChat` (else the most-recently-modified chat), but **promote `InputNeeded` if any chat needs input and `Error` if any chat is errored**. The `IsRead` / `IsArchived` flag bits stay session-scoped.
- `activity` — the activity string of whichever chat drives the status bits.
- `modifiedAt` — the **max** across all chats.
- `workingDirectory` — the session-level **default** only; per-chat overrides on `ChatSummary` are **not** aggregated up (aggregating `model`/`agent` no longer applies — they aren't session/chat-summary fields at all now).
- `changes` — optional roll-up across chats (sum, or the most expensive chat's stats).

Single-chat sessions trivially satisfy all of the above (the chat's values pass through unchanged).

## Multiple active clients per session

A session can have several active clients at once (`agentHost: support multiple active clients per session`). This is modeled purely as protocol state — there is **no** `IAgentHostActiveClientService`.

- `SessionState.activeClients: SessionActiveClient[]` — keyed by `clientId` (the id from `initialize`). Each entry carries `displayName?`, `tools: ToolDefinition[]`, and `customizations?`.
- Lifecycle actions (all client-dispatchable, upsert/remove by `clientId`): `SessionActiveClientSet`, `SessionActiveClientRemoved` (the server SHOULD dispatch this automatically on disconnect), `SessionActiveClientToolsChanged`.
- `createSession` accepts an optional `activeClient` so the creating client can claim the active role atomically (equivalent to dispatching `session/activeClientSet` right after creation).

If multiple clients advertise the same tool, the host MAY dedupe, preferring the client that started the turn.

## Version negotiation

Handshake is SemVer-based. The client sends `InitializeParams.protocolVersions: string[]` ordered from most preferred to least preferred; the server selects one and returns it as `InitializeResult.protocolVersion`. The generated `state/protocol/version/registry.ts` owns `PROTOCOL_VERSION` plus exhaustive introduced-in maps for actions and notifications.

If no offered version is supported, the server throws `UnsupportedProtocolVersion` (-32005) with `UnsupportedProtocolVersionErrorData.supportedVersions` when available. Remote clients translate that into a sticky `RemoteAgentHostConnectionStatus.incompatible` state so the agent window can show a warning rather than treating it like an ordinary network disconnect.

## Capabilities

When a client must feature-detect server support, prefer adding an explicit generated protocol feature/capability over silently changing behavior. This is what keeps older clients compatible with newer servers (and vice versa) once the protocol stabilizes.

The legacy local `sessionCapabilities.ts` helper was removed when generated SemVer negotiation landed. New feature gates should be added to the protocol source/registry in the sibling repo and regenerated here, not reintroduced as a VS Code-only numeric capability table.

`AgentInfo.capabilities?: AgentCapabilities` is the concrete generated instance of this pattern (`agentHost: re-sync protocol types from AHP (AgentCapabilities now generated)`), modeled after MCP-style capability objects: each field's **presence** (even as `{}`) signals support, and absence means the feature is unsupported. Today it has one field, `multipleChats?: MultipleChatsCapability`: presence gates calling `createChat` to open chats beyond the session's initial one; `multipleChats.fork?: boolean` additionally gates passing a `ChatForkSource` to `createChat`. Clients MUST NOT call these commands against an agent that doesn't advertise the corresponding capability. This regenerated a prior hand-edit to `channels-root/state.ts` that had shipped as flat `supportsMultipleChats` / `supportsFork` booleans — a reminder that hand-editing generated protocol files is a stopgap, not a destination.

A separate, more generic mechanism is `root/progress` (`ProgressParams`), a Server → Client notification for long-running operations: a client opts in by sending a `progressToken` on the originating request (today: `createSession`, used to report cold-start SDK-binary downloads for Claude/Codex), and the server emits `progress` / `total` frames until `progress === total`. It is deliberately operation-agnostic — the notification says nothing about *what* is progressing, only that the given token is progressing — so future long-running operations can reuse the same channel without a new method. Like other notifications it is ephemeral and not replayed on reconnect.

## Error model

Errors are JSON-RPC errors with a typed, structured shape (`Agent host rich error handling`). `protocol/errors.ts` (re-exporting `common/errors.ts`) defines:

- `JsonRpcErrorCodes` — the standard JSON-RPC 2.0 codes (`ParseError` -32700 … `InternalError` -32603).
- `AhpErrorCodes` — AHP-specific codes: `SessionNotFound` (-32001), `ProviderNotFound` (-32002), `SessionAlreadyExists` (-32003), `TurnInProgress` (-32004), `UnsupportedProtocolVersion` (-32005), `ContentNotFound` (-32006), `AuthRequired` (-32007), `NotFound` (-32008), `PermissionDenied` (-32009), `AlreadyExists` (-32010), `Conflict` (-32011).
- Structured `data` payloads: `AuthRequiredErrorData { resources: ProtectedResourceMetadata[] }` (required when `AuthRequired`), `PermissionDeniedErrorData { request?: ResourceRequestParams }`, `UnsupportedProtocolVersionErrorData { supportedVersions: string[] }`.

The "rich" part is the type machinery: `AhpError<C extends AhpErrorCode>` is a distributive conditional type, and `AhpErrorDetailsMap` maps each code that carries structured data to its data type. Narrowing on `code` reveals the precise `data` type (required for codes in the map, optional otherwise). When adding a new error condition, add the code to the protocol source and, if it carries structured data, an entry in `AhpErrorDetailsMap` — don't smuggle structured failure detail through the free-form `message`.

`sessionProtocol.ts` re-exports these and keeps a few backward-compat numeric constants (`AHP_SESSION_NOT_FOUND = -32001`, `AHP_AUTH_REQUIRED = -32007`, …) for call sites that haven't migrated to the named codes.

## Important types

- `RootState` — advertised agents, models, protected resources, customizations, active session count, terminals, host-level `config?: RootConfigState`.
- `RootConfigState` — host-level configuration (schema + values), the host-wide counterpart of per-session `SessionConfigState`. Surfaced in the workbench by the host-settings synthetic-file editor (see [agent-host-sessions-providers](./agent-host-sessions-providers.md#settings-editor-file-system-providers)).
- `SessionState` — full session state, **flattened**: `SessionMetadata` fields (`provider`, `title`, `status`, `activity?`, `project?`, `workingDirectory?`, `annotations?`) are inlined directly onto it (`agentHost: adopt flattened SessionState protocol` — no more nested `state.summary`), plus `lifecycle`, the `chats` catalog and `defaultChat`, `activeClients`, server tools, customizations, changesets catalogue, aggregated `inputNeeded`, config. The conversation itself is **not** here — it lives on `ChatState` (chat channel). `SessionSummary` also `extends SessionMetadata` and adds its own catalog-only fields (`resource`, `createdAt`, `modifiedAt`, `changes?`, `_meta?`) — the shared shape is `SessionMetadata`, not a field-by-field coincidence.
- `ChatState` / `ChatSummary` — per-chat conversation state and its lightweight catalog entry. See [Multi-chat sessions](#multi-chat-sessions). `ChatOrigin` / `ChatInteractivity` describe how a chat was created and how interactive it is.
- `SessionStatus` — bit-flag enum on `SessionSummary.status` (replacing the older `isRead` / `isDone` booleans). Includes activity bits (`Idle`, `InProgress`, `InputNeeded`, `Error`) and persistent flags `IsRead` / `IsArchived`. `ChatSummary.status` reuses the same bitset.
- `SessionSummary` / `IAgentSessionMetadata` — lightweight list metadata (`IAgentSessionMetadata` is the VS Code-side wrapper name for what a provider's `listSessions`/`getSessionMetadata` returns). **Do not assume full `SessionState` fields are available in list APIs** — list endpoints return summaries, not full state. For multi-chat sessions, summary fields are aggregated from the chat catalog (see the compat-layer rules above). `SessionSummary.createdAt` / `modifiedAt` are ISO-8601 strings (not epoch numbers) — VS Code call sites that need a numeric timestamp `Date.parse()` them. `SessionSummary.annotations?: AnnotationsSummary` surfaces annotation counts without subscribing to the annotations channel.
- `ConfirmationOption` / `ConfirmationOptionKind` — server-provided confirmation choices on tool-call confirmation actions/state. When set, the client renders these instead of plain approve/deny and echoes back `selectedOptionId` on the answer action. Used to express richer permission choices (e.g. "Allow Once" / "Allow in this Session").
- `SessionActiveClient` — an entry in `SessionState.activeClients[]`, including the client's `tools` and `customizations`. See [Multiple active clients per session](#multiple-active-clients-per-session).
- `AgentCapabilities` / `MultipleChatsCapability` — static, MCP-style opt-in capabilities an `AgentInfo` advertises (currently just `multipleChats?.fork?`). See [Capabilities](#capabilities).
- `ProgressParams` (`root/progress`) — generic, operation-agnostic progress notification correlated by a client-supplied `progressToken`. See [Capabilities](#capabilities).
- `Changeset` / `ChangesetState` / `ChangesetOperation` (changeset channel) — server-declared file-change catalogs and invokable operations (stage / revert / create-pr / …). See [agent-host-git-driven-diffs](./agent-host-git-driven-diffs.md).
- `AnnotationsState` / `Annotation` / `AnnotationEntry` (annotations channel) — file-anchored conversations keyed under `<sessionUri>/annotations`. Used for agent feedback / PR-review comments; feedback semantics ride `Annotation._meta` (`FEEDBACK_ANNOTATION_META_KEY`). See [agent-host-sessions-providers](./agent-host-sessions-providers.md).
- `ActionEnvelope` — server-applied action plus server sequence and optional client origin.
- `AgentSession.provider` / `id` / `uri` — helpers for canonical backend session URIs.
- `InitializeParams.locale` — BCP 47 locale the client passes during `initialize`, so the server can localize confirmation labels and other server-emitted strings.
- `InitializeParams.protocolVersions` / `InitializeResult.protocolVersion` — SemVer negotiation for the connection. Unsupported combinations fail with `UnsupportedProtocolVersion` (-32005) rather than a partial initialize.
- Session config values are typed `Record<string, unknown>` (widened from `Record<string, string>`); `SessionConfigChanged` carries an optional `replace?: boolean` to distinguish merge vs full replacement.
- `SessionState._meta?: Record<string, unknown>` — generic well-known-keyed metadata slot, dispatched by `SessionMetaChanged` and applied by `setSessionMeta` server-side. Today's keys: `git` (`SESSION_META_GIT_KEY`, `ISessionGitState` shape — `hasGitHubRemote` / `branchName` / `baseBranchName` / …, with `readSessionGitState` / `withSessionGitState` helpers) so server-computed git state rides along with normal session-state subscriptions. The related **GitHub** slot lives one level up on `SessionSummary._meta` (`SESSION_META_GITHUB_KEY` = `github`, `ISessionGitHubState { owner; repo; pullRequestUrl }`) so list APIs can show a PR badge without subscribing to full state. Add new well-known keys here rather than expanding the typed surface when a field is conceptually optional, server-computed, and well-known by string key.
- `resourceRequest` / `PermissionDenied` — bidirectional permission negotiation for resource access. A failed resource command may throw `PermissionDenied` (-32009) with `PermissionDeniedErrorData.request`; the caller can then issue `resourceRequest` with that payload and retry if granted.
- `sessionConfigCompletions` and `completions` — generated commands for dynamic config enums and chat-input completions. `InitializeResult.completionTriggerCharacters` tells clients which typed characters should trigger user-message completion requests; completion items may surface commands, skills, and attachment-backed references without introducing client-only inference.
- `SessionInputRequest` plus `SessionInputRequested` / answer / completion actions — generic state for agent-originated user-input requests such as MCP elicitation forms or URL affordances. Providers translate SDK-specific prompts into this protocol shape; clients render and answer it through normal session state.
- `UsageInfo` / `UsageInfoMeta` — per-turn token accounting (`inputTokens`, `outputTokens`, `cacheReadTokens`, `model`, `_meta`). Cost, quota, and Copilot-AIU data are **not** first-class wire fields — they ride `UsageInfo._meta` (`UsageInfoMeta { cost?; copilotUsage?.totalNanoAiu; quotaSnapshots? }`, read via `readUsageInfoMeta` / `readAccountQuotaSnapshot` in `sessionState.ts`).
- `SessionModelInfo._meta` — provider-supplied model metadata bag. Model **pricing** travels here under the well-known `pricing` key (the platform-level `agentModelPricing.ts`: `IAgentModelPricingMeta`, `readAgentModelPricingMeta`, `createPricingMetaFromBilling`, `ICAPIModelBilling`) rather than a Copilot-specific wire field; `agentHostLanguageModelProvider.ts` maps it onto `ILanguageModelChatMetadata` so the chat UI can show multiplier/cost. This **resolves** the long-standing "`SessionModelInfo` has no multiplier/pricing field" debt previously tracked in [agent-host-session-handler](./agent-host-session-handler.md).

## Where to edit

- **Contract changes** (commands, state shapes, actions, reducers, capabilities) → update the protocol source in `../agent-host-protocol`, regenerate `state/protocol/` here, and update Agent Host server tests under `src/vs/platform/agentHost/test/node/`.
- **Client read model behavior** → `agentSubscription.ts` plus `agentSubscription.test.ts`.
- **Reducer semantics** → `sessionReducers.ts` plus `reducers.test.ts`.
- **Server handler behavior** (initialize, subscribe, dispatch, list, create, reconnect, resource, auth) → `src/vs/platform/agentHost/node/protocolServerHandler.ts` plus `protocolServerHandler.test.ts`.

## Patterns and gotchas

- **Prefer pure state and actions** over imperative side channels. If a behavior can be expressed as an action that updates state, do that — it gets reconnection and multi-client behavior for free.
- **Don't bypass `AgentSubscriptionManager`** to read state from the server directly in client code. The subscription is the read model.
- **The list API returns summaries, not full state.** A field that should appear in lists belongs on `SessionSummary` / `AgentSessionMetadata`, not on `SessionState`. Pushing back on upstream protocol changes that put list fields on the wrong type is part of working in this layer.
- **Keep agent-specific knowledge out of state types.** Tool calls expose generic display fields (`displayName`, `invocationMessage`, `pastTenseMessage`, `toolKind`); they never carry raw agent tool names. If you need new rendering behavior, add a new `toolKind` value (a well-known convention — see [agent-host-topology](./agent-host-topology.md#the-two-sanctioned-exceptions-well-known-conventions)), not a tool-name check.
- **Generated feature gates, not silent behavior changes.** When a client must feature-detect server support, add the gate to the protocol source/registry and regenerate VS Code's mirror. Silent behavior changes break older clients against newer servers and vice versa.
- **Resource permissions are negotiated explicitly.** Filesystem-like RPCs must not silently fall through to local access. If a side lacks access, throw `PermissionDenied` with a `resourceRequest` payload where possible; the caller asks for access and retries only after the receiver grants it.
- **Authentication errors are explicit, not empty responses.** When an agent declares `protectedResources` with `required: true` (the default), commands invoked on it before authentication MUST throw `ProtocolError(AHP_AUTH_REQUIRED, ...)` (-32007). Returning an empty result instead — empty session list, empty model list, etc. — is a silent lie that violates the AHP contract and breaks any consumer that caches the first response. The principle the protocol commits to: a response of "I don't know yet" is never indistinguishable from "I know, and the answer is empty." See `copilot-agent-provider.md` for the concrete violation that motivated capturing this rule, and `agent-host-sessions-providers.md` for how the renderer-side `authenticationPending` autorun retries cleanly off the throw.

## Related

- [agent-host-topology](./agent-host-topology.md) — the philosophy behind "neither side is VS Code," the two-app topology, and the well-known conventions exception.
- [agent-host-session-handler](./agent-host-session-handler.md) — how the workbench chat layer consumes session state and dispatches actions.

## Debt & gotchas

- **gotcha** (2026-04-20, AHP authentication contract — `protectedResources.required: true`) — agents whose `protectedResources` declare `required: true` (default) MUST throw `AHP_AUTH_REQUIRED` (-32007) for any command issued before authentication, NOT return empty results. The provider-side temptation is to return `[]` from `listSessions` / model list etc. when no token; that silently breaks one-shot caches in the consumer and causes hard-to-trace UI bugs (sidebar shows nothing forever until something else forces a refresh). See `changes/2026-04-20-fix-initial-session-list-display/` and the concrete rule in `copilot-agent-provider.md`.

## Changelog

- **2026-07-02** — f9f2fd558a — reconciliation: documented the **flattened `SessionState` protocol** (`4678a09ff4a` "Agent host: adopt flattened SessionState protocol") — `SessionMetadata` is now the shared shape inlined onto both `SessionState` and `SessionSummary` (no more nested `state.summary`); `model`/`agent` moved off `SessionState`/`ChatState` entirely onto `Message` (historic messages record what was used, `ChatState.draft` records the in-progress pick), dropping `session/modelChanged` / `session/agentChanged` / `session/activeClientToolsChanged`; `SessionSummary.createdAt`/`modifiedAt` are now ISO-8601 strings. Documented the generated `AgentCapabilities.multipleChats`/`fork` feature gate (`be2fcc3ac7f`, replacing a hand-edited boolean pair) and the generic `root/progress` notification (`cc96f8fbb69`) used today for agent-SDK cold-download progress. Fixed a stale `AgentSessionMetadata` reference to `IAgentSessionMetadata` and replaced "Agents app" wording with "agent window" per current terminology.

- **2026-06-25** — 09c18fe5c5 — reconciliation: major rewrite for the **channel-based wire model** (`protocol/` now splits into `channels-root/-session/-chat/-terminal/-annotations/-changeset/-resource-watch/-otlp` + `common/` + `version/`, with top-level `state.ts` as re-export glue; `state/AGENTS.md` governs and `protocol/` is generated). Added **Multi-chat sessions** (`SessionState.chats` / `defaultChat`, `ChatSummary` / `ChatState` / `ChatOrigin` / `ChatInteractivity`, `createChat` / `disposeChat`, fork via `ChatForkSource`, session-channel catalog actions, and the default-chat `SessionSummary` aggregation compat layer). Added **Multiple active clients per session** (`SessionState.activeClients`, `SessionActiveClient*` actions — modeled as state, no service). Added the **Error model** section (`AhpErrorCodes` -32001..-32011, `AhpError<C>` distributive type, `AhpErrorDetailsMap`, structured `data`). Documented `UsageInfo` / `UsageInfoMeta` cost/quota-on-`_meta`, the **resolved** `SessionModelInfo._meta` pricing slot (`agentModelPricing.ts`), the `SessionSummary._meta.github` slot, and `SessionSummary.annotations`.

- **2026-05-15** — 12443ea83d — reconciliation: documented generated completions, user-input request state, and generic model metadata after `5788cd3ebf8`, `5af88b2d0b5`, `d07965642c9`, and the later elicitation plumbing consumed by providers.

- **2026-05-04** — 939d3f227c — reconciliation: documented SemVer `initialize.protocolVersions` negotiation and `UnsupportedProtocolVersion` (-32005) from `e1a89568eb2`; documented bidirectional `resourceRequest` and `PermissionDenied` (-32009) resource-access negotiation from `c30ed7c4a51`; no body changes needed for subagent URI helpers (`fd6d37812b4`) or eager provisional session internals (`8309b22051c`) because those are service/provider-layer behavior rather than new protocol state shapes.

- **2026-05-01** — b2e6267136 — reconciliation: added the observable adapter note after `b9ef6afd4e5a` introduced `observableFromSubscription`; no body changes needed for `SessionState._meta.git` (`1fa1b7af5c19`) because the existing `_meta` section already captured that well-known slot.
- **2026-04-25** — `8e9b24cedf` — documented the `SessionState._meta` well-known-keyed slot and the first well-known key `git` (`SESSION_META_GIT_KEY`, `ISessionGitState`, `readSessionGitState` / `withSessionGitState` in `sessionState.ts`), dispatched by `SessionMetaChanged` and applied via `setSessionMeta`. See [agent-host-sessions-providers](./agent-host-sessions-providers.md#surfacing-session-_metagit-to-workspacerepositories0) for how the agents-app changes view consumes it (PR [#312543](https://github.com/microsoft/vscode/pull/312543)).
- **2026-04-24** — `5407371c47` — reconciliation: dropped the `I` prefix from generated protocol types in "Important types" and the `ActionEnvelope` snippet (`0b4570038fe` "Adopt renamed agent host protocol types"). Added `RootConfigState` (host-level config on `RootState`, commit `779b23b6196`), `ConfirmationOption`/`ConfirmationOptionKind` for richer permission choices on tool-call confirmations (`779b23b6196`), `SessionStatus` bit flags replacing `isRead`/`isDone` (`037d32ab6b9`), `InitializeParams.locale` (`779b23b6196`), and the eager `activeClient` parameter on `createSession` (`886c556841c`). Noted that session config values widened from `Record<string, string>` to `Record<string, unknown>` and that `SessionConfigChanged` accepts `replace?: boolean`.
- **2026-04-20** — `d05eca7455` — added a "Patterns and gotchas" entry and matching `## Debt & gotchas` entry covering the AHP authentication contract: `required: true` resources MUST throw `AHP_AUTH_REQUIRED`, not return empty results. Triggered by the renderer-side cache-bug investigation in `changes/2026-04-20-fix-initial-session-list-display/`.
- **2026-04-18** — `73bca3fa35` — reconciliation: no doc changes. `a2437aa47e1` ("agentHost: show rich diffs when requesting write confirmations") extracted `IFileEdit` and added `edits` / `editable` / `editedToolInput` fields to tool-call confirmation actions/state — field-level detail not enumerated by this doc, so its architectural prose stays accurate.
- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP architecture as of `origin/main`: generic JSON-RPC + immutable state, URI-addressed root / session / terminal resources, action envelopes with server sequence numbers, optimistic session subscriptions, server-confirmed root/terminal subscriptions, capability-flag versioning. Drawn from the prior `agent-host-chat-sessions` skill.
- **2026-04-16** — `6cd94ddc6f` — added concrete `IActionEnvelope` shape, subscription-class table, file-tree view of `state/`, and a generic-types/capabilities gotcha cross-referencing the new topology doc.
