# Agent Host Protocol (AHP)

_Covers: src/vs/platform/agentHost/common/state/_

The Agent Host Protocol is the wire contract between an AHP **client** (e.g., VS Code workbench, Sessions app, CLI tools) and an AHP **server** (the local utility process or a remote Agent Host). It is intentionally generic: VS Code is one client and the built-in Agent Host process is one server, but the protocol is meant to support other clients and other Agent Host implementations (Copilot SDK, Claude SDK, mock agents).

The mental model is **JSON-RPC plus immutable state**:

- Clients `initialize` (negotiating capabilities), then subscribe to URI-addressed resources.
- Clients create / list / dispose sessions, dispatch actions, and receive **action envelopes** plus notifications.
- Reconnection works by **replay** (action sequence numbers) or **snapshot**.

## Where it lives

- **Generated protocol surface:** `src/vs/platform/agentHost/common/state/protocol/` — files here say `DO NOT EDIT`. The external source of truth is the sibling repo `../agent-host-protocol`. Regenerate / sync from there when the contract changes.
- **VS Code-facing re-exports and compatibility shims** (sit beside `protocol/`):
  - `sessionProtocol.ts` — re-exports of the protocol surface used by client code.
  - `sessionState.ts` — the shapes consumed by VS Code (root, session, terminal).
  - `sessionActions.ts` — action types dispatched by clients and applied by the server.
  - `sessionReducers.ts` — reducers used both server-side (for canonical state) and client-side (for optimistic application).
  - `sessionCapabilities.ts` — capability flags for feature-detection across protocol versions.
  - `agentSubscription.ts` — `AgentSubscriptionManager`, the client read model.
  - `sessionTransport.ts` — transport abstractions (over MessagePort, WebSocket, etc).

## Resource addressing

State is URI-addressed.

- **Root state:** `agenthost:/root` — advertised agents, models, protected resources, customizations, active session count, terminals.
- **Session state:** keyed by provider URI such as `copilot:/<rawId>` or `mock:/<rawId>`. Use `AgentSession.uri(provider, rawId)` to construct canonically.
- **Terminal state:** keyed by terminal URI. Used by terminal subscriptions.

## Subscriptions

`AgentSubscriptionManager` (in `agentSubscription.ts`) gives clients a reactive read model:

- **Session subscriptions** support optimistic write-ahead and reconciliation: a client can apply an action locally before the server confirms, then reconcile when the action envelope arrives with the server-assigned sequence number.
- **Root and terminal subscriptions** are server-confirmed (no optimistic writes).

This is the right place to look when reasoning about what state a client sees vs. what the server has applied.

## Action envelopes

Every server-applied action is wrapped in an `IActionEnvelope` that carries the server sequence number and (when applicable) the originating client's tag. Clients use the sequence number for replay-based reconnection and the origin tag to recognize their own optimistic actions coming back as confirmed.

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

## Related

- [agent-host-session-handler](./agent-host-session-handler.md) — how the workbench chat layer consumes session state and dispatches actions.

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP architecture as of `origin/main`: generic JSON-RPC + immutable state, URI-addressed root / session / terminal resources, action envelopes with server sequence numbers, optimistic session subscriptions, server-confirmed root/terminal subscriptions, capability-flag versioning. Drawn from the prior `agent-host-chat-sessions` skill.
