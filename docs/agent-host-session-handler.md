# Agent Host Session Handler

_Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts_

`AgentHostSessionHandler` is the shared adapter between **AHP session state** (see [agent-host-protocol](./agent-host-protocol.md)) and **VS Code chat sessions**. It powers chat for both standard VS Code (workbench) and the Sessions app — the difference is how sessions get exposed to the UI, not how a session itself is run.

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
- Showing sessions in the Sessions app — that's the `*AgentHostSessionsProvider` family under `src/vs/sessions/contrib/`.

## Local vs. remote

The handler is connection-agnostic: it works against `IAgentConnection`, which both the local and remote implementations satisfy. Lifecycle controls that are local-only (restart, WebSocket server startup) live on `IAgentHostService`, not on the handler.

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

- [agent-host-protocol](./agent-host-protocol.md) — the contract this handler consumes and dispatches against.

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the role of `AgentHostSessionHandler` as the shared local/remote adapter between AHP session state and VS Code chat sessions, including turn dispatch, progress rendering, active-turn reconnect, server-initiated turns, permissions, client tools, file edits, terminals, subagents, auth retries, and customization refs. Drawn from the prior `agent-host-chat-sessions` skill.
