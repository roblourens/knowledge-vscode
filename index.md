# Agent Host Knowledge Index

The entry point for the VS Code agent host knowledge base. Read this file first to orient, then pull the specific docs and task guides relevant to your task.

## What this knowledge base covers

The VS Code **agent host** is the subsystem that hosts AI coding agents (Copilot, Claude, mocks, and remote/SSH/tunnel-relayed agents) inside VS Code. It owns:

- An **Agent Host Protocol (AHP)** — JSON-RPC + immutable state — that decouples the protocol layer from any specific agent or client.
- A **local Agent Host process** (utility process on desktop) that implements the server side of AHP for the built-in agents.
- **Remote Agent Host connections** over WebSocket, SSH relay, and tunnel relay.
- A **workbench chat integration** that adapts AHP session state to VS Code chat sessions, file-edit checkpoints, terminals, language model selection, customizations, and auth.
- **Sessions app providers** that expose Agent Host sessions in the Agents/Sessions UI for both local and remote hosts.

Docs in this knowledge base are scoped to *one component or concern* each, with a `Covers:` line declaring the VS Code paths the doc is primarily concerned with. Use the `Covers:` lists below to find the right doc for a task; follow inline cross-references inside docs to reach adjacent context.

## Major architectural layers

1. **Protocol layer** — `src/vs/platform/agentHost/common/state/`, plus the generated `state/protocol/` source synced from the sibling `agent-host-protocol` repo.
2. **Process and connection layer** — local utility process via MessagePort (`IAgentHostService`), remote WebSocket / SSH / tunnel connections (`IRemoteAgentHostService`), all behind `IAgentConnection`.
3. **Workbench chat integration** — `AgentHostContribution`, `AgentHostSessionHandler`, `AgentHostEditingSession`, model and customization providers, under `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/`.
4. **Sessions app providers** — `LocalAgentHostSessionsProvider`, `RemoteAgentHostSessionsProvider`, `TunnelAgentHostContribution`, under `src/vs/sessions/contrib/`.

## Docs

- [agent-host-protocol](docs/agent-host-protocol.md) — the AHP wire contract: state, actions, reducers, capabilities, subscriptions, and how the generated `state/protocol/` source relates to the sibling `agent-host-protocol` repo. _Covers: src/vs/platform/agentHost/common/state/_
- [agent-host-session-handler](docs/agent-host-session-handler.md) — `AgentHostSessionHandler`, the shared adapter between AHP session state and VS Code chat sessions: turn dispatch, progress rendering, active-turn reconnect, server-initiated turns, permissions, client tools, file edits, terminals, subagents, auth retries, customization refs. _Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts_

_(More docs to come. As they're added, list them here with a one-line keyword-rich description plus a `Covers:` line.)_

## Tasks

_(Task guides — reusable how-to references for recurring work patterns — go here as they're written. Examples to come: `updating-the-protocol`, `test-strategies`, `interactive-verification`.)_

## Recent changes

The `changes/` directory contains one subfolder per significant session, named `YYYY-MM-DD-short-description/`. Browse it directly for the narrative of how the system has evolved. The most recent few entries are usually the most useful context when working on adjacent areas.

## Conventions

- **Doc scope:** one component or concern per doc, with a `Covers:` line listing the VS Code paths the doc is primarily concerned with. If the `Covers:` list doesn't fit in a sentence, the doc is too broad — split it.
- **Cross-linking:** plain Markdown relative links inline where relevant. This index is the only file that tries to be exhaustive.
- **Changelog per doc:** every doc ends with a `Changelog` section. Each entry: `**YYYY-MM-DD** — <short SHA> — <summary>`. Use a 10-character abbreviated SHA (e.g. via `git rev-parse --short=10`) — readable, and still unambiguous in practice. The most recent entry's SHA is the baseline that `reconcile` diffs against.
- **Source of truth is the code.** When a doc and the code disagree, the code wins. Update the doc.
