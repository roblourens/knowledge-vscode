# Agent Host Session Handler

_Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts_

`AgentHostSessionHandler` is the **shared** adapter between AHP session state (see [agent-host-protocol](./agent-host-protocol.md)) and VS Code chat sessions. The same handler runs in all three deployment configurations — VS Code with a local agent host, the Agents app with a local agent host, and the Agents app with one or more remote agent hosts. For the topology and what `connectionAuthority` / `sessionType` mean, see [agent-host-topology](./agent-host-topology.md).

## What it owns

For each chat session backed by an Agent Host, the handler:

- **Creates and subscribes** to the backend session (via `IAgentConnection`), translating the workbench-side session id ↔ canonical AHP session URI (`copilot:/<rawId>` etc.).
- **Converts chat requests into `session/turnStarted`** dispatches.
- **Renders state into chat history and progress** by adapting `ISessionState` updates into chat content parts and progress messages.
- **Handles active-turn reconnection** — if the workbench reattaches mid-turn (after reload, host change, or network blip), the handler resumes rendering from the protocol's replay/snapshot.
- **Handles server-initiated turns** — turns the agent starts on its own, not in response to a user message.
- **Dispatches cancellations** back through the protocol.
- **Renders permission prompts** (tool/file approvals) as VS Code permission UI and forwards the user's choice back as an action.
- **Hosts client tools** — tools the workbench provides to the session (allowlist controlled via `chat.agentHost.clientTools`); see `agentHostClientTools.ts`.
- **Coordinates file edits** through `AgentHostEditingSession` (`agentHostEditingSession.ts`), which adapts AHP file-edit content into chat editing/checkpoint behavior and uses the Agent Host filesystem connection to read/write snapshots.
- **Coordinates terminals** via terminal state subscriptions and terminal actions on the connection.
- **Coordinates subagents** that the session spawns.
- **Retries on auth-required errors** by calling `authenticate` on the connection (using protected resources advertised in `IRootState`) and re-dispatching.
- **Forwards customization refs** so the active client's customizations apply to the running session.

## What it does NOT own

- Choosing models — that's `AgentHostLanguageModelProvider` (`agentHostLanguageModelProvider.ts`).
- Discovering agents and registering chat session contributions — that's `AgentHostContribution` (`agentHostChatContribution.ts`), which listens to local `rootState.agents` and dynamically registers one chat session type per advertised agent (`agent-host-${agent.provider}`).
- Listing sessions in the workbench chat list — that's `AgentHostSessionListController` (`agentHostSessionListController.ts`), backed by `connection.listSessions()`.
- Showing sessions in the Sessions app — that's the `*AgentHostSessionsProvider` family under `src/vs/sessions/contrib/`; see [agent-host-sessions-providers](./agent-host-sessions-providers.md).

## Local vs. remote

The handler is connection-agnostic: it works against `IAgentConnection`, which both the local and remote implementations satisfy. The same `AgentHostSessionHandler` class is constructed with a config like:

```typescript
interface IAgentHostSessionHandlerConfig {
    readonly provider: AgentProvider;     // e.g. 'copilot'
    readonly agentId: string;
    readonly sessionType: string;          // identifies (host × agent) in chat sessions
    readonly fullName: string;
    readonly description: string;
    readonly connection: IAgentConnection; // local MessagePort | remote WS/SSH/tunnel
    readonly connectionAuthority: string;  // 'local' | sanitized remote name
}
```

Local wiring is in `agentHostChatContribution.ts` (`AgentHostContribution`); remote wiring is in `src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts` (`RemoteAgentHostContribution`). They differ only in how `sessionType`, `connectionAuthority`, and `connection` are derived.

Lifecycle controls that are local-only (restart, dev-mode startup) live on `IAgentHostService`, not on the handler. If the handler reaches for `IAgentHostService` instead of `IAgentConnection` for a behavior that should also work remotely, that's a bug.

## Editing through the handler vs. directly

Code that *runs a turn* belongs in the handler. Code that *changes how a turn is displayed* belongs in the handler's adapter helpers (e.g., `stateToProgressAdapter.ts`). Code that *changes the protocol contract* belongs in [agent-host-protocol](./agent-host-protocol.md), not here.

If a behavior could be expressed as a protocol action and reducer change, prefer that — handler-only state tends to drift across local/remote and across multi-client scenarios.

## Patterns and gotchas

- **Active-turn reconnect** is the most subtle behavior. If you change how a turn renders, exercise reload-during-turn paths in tests under `agentHostChatContribution.test.ts`.
- **The same handler instance does not span sessions.** Per-session state lives on the handler instance for that session.
- **Disposables register at construction time.** Don't add manual `dispose()` — use `this._register(...)`.
- **Preserve the `IAgentConnection` abstraction.** Reach for `IAgentHostService` only when you need a local-lifecycle API (restart, etc.).
- **Customization refs flow through the protocol.** Don't piggyback on workbench-side state to communicate customization changes to the server; use `ISessionActiveClient` and customization actions.

## Where to edit

- Turn rendering, progress, history, cancellation, server-initiated turns, permissions, customization refs → `agentHostSessionHandler.ts`.
- Adapter helpers (state → progress) → `stateToProgressAdapter.ts`.
- File edits / checkpoints → `agentHostEditingSession.ts`.
- Client tools (definition/result conversion, allowlist) → `agentHostClientTools.ts`.
- Auth retry behavior → `agentHostAuth.ts`.

## Tests

- `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostChatContribution.test.ts` — dynamic registration, session id mapping, create/subscribe, progress rendering, cancellation, errors, permission requests, history, tool rendering, attachments, dynamic discovery, config forwarding, **active-turn reconnect**, server-initiated turns, customizations.
- `agentHostClientTools.test.ts` — tool definition/result conversion, allowlist filtering, active-client tool updates.
- `src/vs/workbench/contrib/chat/test/browser/agentHost/agentHostEditingSession.test.ts` — file edit hydration, undo/redo, snapshots, checkpoint disablement.

When changing the handler, run the workbench adapter tests *and* the protocol/server tests for the underlying behavior — the handler often surfaces server-side bugs.

## Related

- [agent-host-topology](./agent-host-topology.md) — the two-app topology and three deployment configurations the handler runs in.
- [agent-host-protocol](./agent-host-protocol.md) — the contract this handler consumes and dispatches against.
- [agent-host-sessions-providers](./agent-host-sessions-providers.md) — the other consumer of the same `StateComponents.Session` subscriptions, in the Sessions app.

## Debt & gotchas

_(Empty for now. Entries take the form `- **debt|gotcha** (YYYY-MM-DD, file:symbol) — description`.)_

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the role of `AgentHostSessionHandler` as the shared local/remote adapter between AHP session state and VS Code chat sessions, including turn dispatch, progress rendering, active-turn reconnect, server-initiated turns, permissions, client tools, file edits, terminals, subagents, auth retries, and customization refs. Drawn from the prior `agent-host-chat-sessions` skill.
- **2026-04-16** — `6cd94ddc6f` — added `IAgentHostSessionHandlerConfig` example showing the local-vs-remote seam, and cross-referenced the new topology doc.
- **2026-04-18** — `96ab46a042` — cross-linked to the new agent-host-sessions-providers doc; clarified that the providers share the same refcounted `StateComponents.Session` subscriptions.
