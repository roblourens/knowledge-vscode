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
│                                source of truth: ../agent-host-protocol repo
├── sessionProtocol.ts        ← re-exports of the protocol surface for client code
├── sessionState.ts           ← root / session / terminal state shapes
├── sessionActions.ts         ← action types dispatched by clients, applied by server
├── sessionReducers.ts        ← reducers, used server-side AND client-side (optimistic)
├── agentSubscription.ts      ← AgentSubscriptionManager — the client read model
└── sessionTransport.ts       ← transport abstractions (MessagePort, WebSocket, ...)
```

When the contract changes, the workflow is: edit the [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) repo first, regenerate the `protocol/` subdir here, then update the surrounding shims and the server handler.

## Resource addressing

State is URI-addressed.

- **Root state:** `agenthost:/root` — advertised agents, models, protected resources, customizations, active session count, terminals, and host-level config (`RootState.config?: RootConfigState`).
- **Session state:** keyed by provider URI such as `copilot:/<rawId>` or `mock:/<rawId>`. Use `AgentSession.uri(provider, rawId)` to construct canonically.
- **Terminal state:** keyed by terminal URI. Used by terminal subscriptions.

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

## Version negotiation

Handshake is SemVer-based. The client sends `InitializeParams.protocolVersions: string[]` ordered from most preferred to least preferred; the server selects one and returns it as `InitializeResult.protocolVersion`. The generated `state/protocol/version/registry.ts` owns `PROTOCOL_VERSION` plus exhaustive introduced-in maps for actions and notifications.

If no offered version is supported, the server throws `UnsupportedProtocolVersion` (-32005) with `UnsupportedProtocolVersionErrorData.supportedVersions` when available. Remote VS Code clients translate that into a sticky `RemoteAgentHostConnectionStatus.incompatible` state so the Agents app can show a warning rather than treating it like an ordinary network disconnect.

## Capabilities

When a client must feature-detect server support, prefer adding an explicit generated protocol feature/capability over silently changing behavior. This is what keeps older clients compatible with newer servers (and vice versa) once the protocol stabilizes.

The legacy local `sessionCapabilities.ts` helper was removed when generated SemVer negotiation landed. New feature gates should be added to the protocol source/registry in the sibling repo and regenerated here, not reintroduced as a VS Code-only numeric capability table.

## Important types

- `RootState` — advertised agents, models, protected resources, customizations, active session count, terminals, host-level `config?: RootConfigState`.
- `RootConfigState` — host-level configuration (schema + values), the host-wide counterpart of per-session `SessionConfigState`. Surfaced in the workbench by the host-settings synthetic-file editor (see [agent-host-sessions-providers](./agent-host-sessions-providers.md#settings-editor-file-system-providers)).
- `SessionState` — full session state: summary, lifecycle, turns, active turn, server tools, active client, pending/queued messages, input requests, config, customizations.
- `SessionStatus` — bit-flag enum on `SessionSummary.status` (replacing the older `isRead` / `isDone` booleans). Includes activity bits (`Idle`, `InProgress`, `InputNeeded`, `Error`) and persistent flags `IsRead` / `IsArchived`.
- `SessionSummary` / `AgentSessionMetadata` — lightweight list metadata. **Do not assume full `SessionState` fields are available in list APIs** — list endpoints return summaries, not full state.
- `ConfirmationOption` / `ConfirmationOptionKind` — server-provided confirmation choices on tool-call confirmation actions/state. When set, the client renders these instead of plain approve/deny and echoes back `selectedOptionId` on the answer action. Used to express richer permission choices (e.g. "Allow Once" / "Allow in this Session").
- `SessionActiveClient` — the currently active client for a session, including the client's tools and customizations. `createSession` now accepts an optional `activeClient` param so the creating client can claim the session atomically (no separate post-create `ActiveClientChanged` round-trip).
- `ActionEnvelope` — server-applied action plus server sequence and optional client origin.
- `AgentSession.provider` / `id` / `uri` — helpers for canonical backend session URIs.
- `InitializeParams.locale` — BCP 47 locale the client passes during `initialize`, so the server can localize confirmation labels and other server-emitted strings.
- `InitializeParams.protocolVersions` / `InitializeResult.protocolVersion` — SemVer negotiation for the connection. Unsupported combinations fail with `UnsupportedProtocolVersion` (-32005) rather than a partial initialize.
- Session config values are typed `Record<string, unknown>` (widened from `Record<string, string>`); `SessionConfigChanged` carries an optional `replace?: boolean` to distinguish merge vs full replacement.
- `SessionState._meta?: Record<string, unknown>` — generic well-known-keyed metadata slot, dispatched by `SessionMetaChanged` and applied by `setSessionMeta` server-side. Used today for the `git` slot (`SESSION_META_GIT_KEY`, with `ISessionGitState` shape and `readSessionGitState` / `withSessionGitState` helpers in `sessionState.ts`) so server-computed git state can ride along with normal session-state subscriptions instead of needing a bespoke command. Add new well-known keys here rather than expanding the typed `SessionState` surface when a field is conceptually optional, server-computed, and well-known by string key.
- `resourceRequest` / `PermissionDenied` — bidirectional permission negotiation for resource access. A failed resource command may throw `PermissionDenied` (-32009) with `PermissionDeniedErrorData.request`; the caller can then issue `resourceRequest` with that payload and retry if granted.
- `sessionConfigCompletions` and `completions` — generated commands for dynamic config enums and chat-input completions. `InitializeResult.completionTriggerCharacters` tells clients which typed characters should trigger user-message completion requests; completion items may surface commands, skills, and attachment-backed references without introducing client-only inference.
- `SessionInputRequest` plus `SessionInputRequested` / answer / completion actions — generic state for agent-originated user-input requests such as MCP elicitation forms or URL affordances. Providers translate SDK-specific prompts into this protocol shape; clients render and answer it through normal session state.
- `SessionModelInfo._meta` — provider-supplied model metadata bag. Pricing/multiplier data now travels through this generic slot rather than growing a Copilot-specific wire field.

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

- **2026-05-15** — 12443ea83d — reconciliation: documented generated completions, user-input request state, and generic model metadata after `5788cd3ebf8`, `5af88b2d0b5`, `d07965642c9`, and the later elicitation plumbing consumed by providers.

- **2026-05-04** — 939d3f227c — reconciliation: documented SemVer `initialize.protocolVersions` negotiation and `UnsupportedProtocolVersion` (-32005) from `e1a89568eb2`; documented bidirectional `resourceRequest` and `PermissionDenied` (-32009) resource-access negotiation from `c30ed7c4a51`; no body changes needed for subagent URI helpers (`fd6d37812b4`) or eager provisional session internals (`8309b22051c`) because those are service/provider-layer behavior rather than new protocol state shapes.

- **2026-05-01** — b2e6267136 — reconciliation: added the observable adapter note after `b9ef6afd4e5a` introduced `observableFromSubscription`; no body changes needed for `SessionState._meta.git` (`1fa1b7af5c19`) because the existing `_meta` section already captured that well-known slot.
- **2026-04-25** — `8e9b24cedf` — documented the `SessionState._meta` well-known-keyed slot and the first well-known key `git` (`SESSION_META_GIT_KEY`, `ISessionGitState`, `readSessionGitState` / `withSessionGitState` in `sessionState.ts`), dispatched by `SessionMetaChanged` and applied via `setSessionMeta`. See [agent-host-sessions-providers](./agent-host-sessions-providers.md#surfacing-session-_metagit-to-workspacerepositories0) for how the agents-app changes view consumes it (PR [#312543](https://github.com/microsoft/vscode/pull/312543)).
- **2026-04-24** — `5407371c47` — reconciliation: dropped the `I` prefix from generated protocol types in "Important types" and the `ActionEnvelope` snippet (`0b4570038fe` "Adopt renamed agent host protocol types"). Added `RootConfigState` (host-level config on `RootState`, commit `779b23b6196`), `ConfirmationOption`/`ConfirmationOptionKind` for richer permission choices on tool-call confirmations (`779b23b6196`), `SessionStatus` bit flags replacing `isRead`/`isDone` (`037d32ab6b9`), `InitializeParams.locale` (`779b23b6196`), and the eager `activeClient` parameter on `createSession` (`886c556841c`). Noted that session config values widened from `Record<string, string>` to `Record<string, unknown>` and that `SessionConfigChanged` accepts `replace?: boolean`.
- **2026-04-20** — `d05eca7455` — added a "Patterns and gotchas" entry and matching `## Debt & gotchas` entry covering the AHP authentication contract: `required: true` resources MUST throw `AHP_AUTH_REQUIRED`, not return empty results. Triggered by the renderer-side cache-bug investigation in `changes/2026-04-20-fix-initial-session-list-display/`.
- **2026-04-18** — `73bca3fa35` — reconciliation: no doc changes. `a2437aa47e1` ("agentHost: show rich diffs when requesting write confirmations") extracted `IFileEdit` and added `edits` / `editable` / `editedToolInput` fields to tool-call confirmation actions/state — field-level detail not enumerated by this doc, so its architectural prose stays accurate.
- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP architecture as of `origin/main`: generic JSON-RPC + immutable state, URI-addressed root / session / terminal resources, action envelopes with server sequence numbers, optimistic session subscriptions, server-confirmed root/terminal subscriptions, capability-flag versioning. Drawn from the prior `agent-host-chat-sessions` skill.
- **2026-04-16** — `6cd94ddc6f` — added concrete `IActionEnvelope` shape, subscription-class table, file-tree view of `state/`, and a generic-types/capabilities gotcha cross-referencing the new topology doc.
