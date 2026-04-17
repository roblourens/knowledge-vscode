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
├── sessionCapabilities.ts    ← capability flags for feature-detection
├── agentSubscription.ts      ← AgentSubscriptionManager — the client read model
└── sessionTransport.ts       ← transport abstractions (MessagePort, WebSocket, ...)
```

When the contract changes, the workflow is: edit the [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) repo first, regenerate the `protocol/` subdir here, then update the surrounding shims and the server handler.

## Resource addressing

State is URI-addressed.

- **Root state:** `agenthost:/root` — advertised agents, models, protected resources, customizations, active session count, terminals.
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

## Action envelopes

Every server-applied action is wrapped in an `IActionEnvelope`:

```typescript
interface IActionEnvelope {
    readonly seq: number;        // server-assigned sequence number
    readonly action: ISessionAction;
    readonly origin?: string;    // tag of the client that dispatched (if any)
}
```

The `seq` drives **replay-based reconnection**: a client that drops and reattaches asks for actions since its last seen `seq`, and the server fills in the gap (or sends a fresh snapshot if the gap is too large). The `origin` lets a client recognize its own optimistic action coming back as confirmed and reconcile it with what the server actually applied (which can differ — e.g. the server may have rejected or transformed it).

## Capabilities and versioning

`sessionCapabilities.ts` lists capability flags. When a client must feature-detect server support, prefer adding a capability over silently changing behavior. This is what keeps older clients compatible with newer servers (and vice versa).

## Important types

- `IRootState` — advertised agents, models, protected resources, customizations, active session count, terminals.
- `ISessionState` — full session state: summary, lifecycle, turns, active turn, server tools, active client, pending/queued messages, input requests, config, customizations.
- `ISessionSummary` / `IAgentSessionMetadata` — lightweight list metadata. **Do not assume full `ISessionState` fields are available in list APIs** — list endpoints return summaries, not full state.
- `ISessionActiveClient` — the currently active client for a session, including the client's tools and customizations.
- `IActionEnvelope` — server-applied action plus server sequence and optional client origin.
- `AgentSession.provider` / `id` / `uri` — helpers for canonical backend session URIs.

## Where to edit

- **Contract changes** (commands, state shapes, actions, reducers, capabilities) → update the protocol source in `../agent-host-protocol`, regenerate `state/protocol/` here, and update Agent Host server tests under `src/vs/platform/agentHost/test/node/`.
- **Client read model behavior** → `agentSubscription.ts` plus `agentSubscription.test.ts`.
- **Reducer semantics** → `sessionReducers.ts` plus `reducers.test.ts`.
- **Server handler behavior** (initialize, subscribe, dispatch, list, create, reconnect, resource, auth) → `src/vs/platform/agentHost/node/protocolServerHandler.ts` plus `protocolServerHandler.test.ts`.

## Patterns and gotchas

- **Prefer pure state and actions** over imperative side channels. If a behavior can be expressed as an action that updates state, do that — it gets reconnection and multi-client behavior for free.
- **Don't bypass `AgentSubscriptionManager`** to read state from the server directly in client code. The subscription is the read model.
- **The list API returns summaries, not full state.** A field that should appear in lists belongs on `ISessionSummary` / `IAgentSessionMetadata`, not on `ISessionState`. Pushing back on upstream protocol changes that put list fields on the wrong type is part of working in this layer.
- **Keep agent-specific knowledge out of state types.** Tool calls expose generic display fields (`displayName`, `invocationMessage`, `pastTenseMessage`, `toolKind`); they never carry raw agent tool names. If you need new rendering behavior, add a new `toolKind` value (a well-known convention — see [agent-host-topology](./agent-host-topology.md#the-two-sanctioned-exceptions-well-known-conventions)), not a tool-name check.
- **Capability flags, not silent behavior changes.** When a client must feature-detect server support, add a flag to `sessionCapabilities.ts`. Silent behavior changes break older clients against newer servers and vice versa.

## Related

- [agent-host-topology](./agent-host-topology.md) — the philosophy behind "neither side is VS Code," the two-app topology, and the well-known conventions exception.
- [agent-host-session-handler](./agent-host-session-handler.md) — how the workbench chat layer consumes session state and dispatches actions.

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP architecture as of `origin/main`: generic JSON-RPC + immutable state, URI-addressed root / session / terminal resources, action envelopes with server sequence numbers, optimistic session subscriptions, server-confirmed root/terminal subscriptions, capability-flag versioning. Drawn from the prior `agent-host-chat-sessions` skill.
- **2026-04-16** — `6cd94ddc6f` — added concrete `IActionEnvelope` shape, subscription-class table, file-tree view of `state/`, and a generic-types/capabilities gotcha cross-referencing the new topology doc.
