# Agent Host Knowledge Index

The entry point for the VS Code agent host knowledge base. Read this file first to orient, then pull the specific docs relevant to your task.

## What this knowledge base covers

The VS Code **agent host** is the subsystem that hosts AI coding agents (Copilot, Claude, mocks, and remote/SSH/tunnel-relayed agents) inside VS Code. It owns:

- An **Agent Host Protocol (AHP)** — JSON-RPC + immutable state — that decouples the protocol layer from any specific agent or client.
- A **local Agent Host process** (utility process on desktop) that implements the server side of AHP for the built-in agents.
- **Remote Agent Host connections** over WebSocket, SSH relay, and tunnel relay.
- A **workbench chat integration** that adapts AHP session state to VS Code chat sessions, file-edit checkpoints, terminals, language model selection, customizations, and auth.
- **Sessions app providers** that expose Agent Host sessions in the Agents/Sessions UI for both local and remote hosts.

Docs in this knowledge base are scoped to *one component or concern* each, with a `Covers:` line declaring the VS Code paths the doc is primarily concerned with. Use the `Covers:` lists below to find the right doc for a task; follow inline cross-references inside docs to reach adjacent context.

## Start here: the defining property and the principles

Before reading any component-level doc, internalize two things from [agent-host-topology](docs/agent-host-topology.md):

1. **The agent runs without a client. The client is a viewer/controller that comes and goes.** This single property explains why the host is a long-lived process, why state + reducers + `serverSeq` exists, why file edits land where the agent runs, and why multi-client correctness is a corollary rather than the goal.
2. **The eight Principles** at the bottom of that doc — generic by construction; design for the spec and the in-tree consumer; greenfield velocity over back-compat; agent-autonomous; state+reducers for session state but commands for service RPCs; protocol-level uniformity over SDK fidelity; layering over collapsing; pragmatism over purity.

For the AHP-vs-ACP question ("why a new protocol?"), see the sibling repo's [docs/guide/ahp-and-acp.md](https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/ahp-and-acp.md): AHP is a coordination layer for N clients sharing a host; ACP is 1:1 communication between a client and an agent. They compose; today our first-party agents (Copilot, future Claude) sit in-process as `IAgent` implementations rather than via ACP.

## Major architectural layers

1. **Protocol layer** — `src/vs/platform/agentHost/common/state/`, plus the generated `state/protocol/` source synced from the sibling `agent-host-protocol` repo.
2. **Process and connection layer** — local utility process via MessagePort (`IAgentHostService`), remote WebSocket / SSH / tunnel connections (`IRemoteAgentHostService`), all behind `IAgentConnection`.
3. **Workbench chat integration** — `AgentHostContribution`, `AgentHostSessionHandler`, `AgentHostEditingSession`, model and customization providers, under `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/`.
4. **Sessions app providers** — `LocalAgentHostSessionsProvider`, `RemoteAgentHostSessionsProvider`, `TunnelAgentHostContribution`, under `src/vs/sessions/contrib/`.

## Docs

Read in this order if you're new — each one assumes the previous.

- [agent-host-topology](docs/agent-host-topology.md) — **start here.** The orientation doc: AHP's generic-protocol philosophy ("neither side is VS Code") and its corollary ("but design for the spec and our in-tree client, not theoretical external ones"), the two sanctioned convention exceptions (well-known config property names; tool-call kinds + metadata), the two-app topology (VS Code app vs Agents app, the latter still rooted at `src/vs/sessions/`), the three deployment configurations, remote host scoping in the Agents app, and the where-to-put-new-code decision tree. _Covers: src/vs/platform/agentHost/, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/remoteAgentHost/, src/vs/sessions/contrib/sessions/browser/views/sessionsList.ts, src/vs/sessions/contrib/chat/browser/scopedWorkspacePicker.ts_
- [agent-host-protocol](docs/agent-host-protocol.md) — the AHP wire contract: state, actions, reducers, capabilities, subscriptions, action envelopes, and how the generated `state/protocol/` source relates to the sibling `agent-host-protocol` repo. _Covers: src/vs/platform/agentHost/common/state/_
- [copilot-agent-provider](docs/copilot-agent-provider.md) — the local Copilot Agent Host provider: SDK client lifecycle, session create/resume/list, per-session database metadata, and the database-existence ownership gate for filtering SDK sessions. _Covers: src/vs/platform/agentHost/node/copilot/copilotAgent.ts, src/vs/platform/agentHost/test/node/copilotAgent.test.ts_
- [agent-host-session-handler](docs/agent-host-session-handler.md) — `AgentHostSessionHandler`, the shared adapter between AHP session state and VS Code chat sessions: turn dispatch, progress rendering, active-turn reconnect, server-initiated turns, permissions, client tools, file edits, terminals, subagents, auth retries, customization refs. _Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts_
- [agent-host-sessions-providers](docs/agent-host-sessions-providers.md) — local and remote Agent Host sessions providers for the Sessions app: shared `BaseAgentHostSessionsProvider` + `AgentHostSessionAdapter`, list/open, dynamic session-config picker, lazy `ISessionState.config` subscription seeding, and the persistence/restore bridge through `AgentService` + `AgentSideEffects`. _Covers: src/vs/sessions/contrib/agentHost/browser/baseAgentHostSessionsProvider.ts, src/vs/sessions/contrib/agentHost/browser/localAgentHostSessionsProvider.ts, src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHostSessionsProvider.ts, src/vs/sessions/common/agentHostSessionsProvider.ts_
- [agent-host-auto-approve-picker](docs/agent-host-auto-approve-picker.md) — the well-known `autoApprove` session-config property and how it bridges into the **two** existing permission picker widgets (sessions-layer `PermissionPicker` for the new-chat page; workbench-layer `PermissionPickerActionItem` for the running chat input toolbar) via a shared delegate. Covers the recognition predicate, fallback to the generic per-property picker for non-conforming agents, and the reactive-visibility pattern needed for `IActionViewItemService` factories. _Covers: src/vs/sessions/contrib/chat/browser/agentHost/, src/vs/sessions/contrib/copilotChatSessions/browser/permissionPicker.ts, src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts_
- [agent-host-remote-protocol-client](docs/agent-host-remote-protocol-client.md) — remote `IAgentConnection` request lifecycle, structured JSON-RPC errors, close/dispose ordering, extension-request typing, and remaining reconnect/transport debt. _Covers: src/vs/platform/agentHost/browser/remoteAgentHostProtocolClient.ts, src/vs/platform/agentHost/browser/webSocketClientTransport.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostProtocolClient.test.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostService.test.ts_
- [testing](docs/testing.md) — the four test layers for the agent host (unit, protocol integration, real-SDK integration, workbench/UI), how to run each, when to pick which, and workflow gotchas (`unset ELECTRON_RUN_AS_NODE`, retranspile before integration runs, validating regression tests by reverting the fix). _Covers: src/vs/platform/agentHost/test/, src/vs/workbench/contrib/chat/test/browser/agentSessions/, src/vs/workbench/contrib/chat/test/browser/agentHost/_

_(More docs to come. As they're added, list them here with a one-line keyword-rich description plus a `Covers:` line.)_

## Active debt & gotchas

Cross-cutting items only. Per-component items live in each doc's `## Debt & gotchas` section — always read it for any doc whose `Covers:` overlaps your task.

- **gotcha (layer rule for `vs/sessions/`)** — code under `src/vs/sessions/~` (i.e. `browser/`, `common/`, `node/` directly under `sessions/`) cannot import from `src/vs/workbench/contrib/*`; only `src/vs/sessions/contrib/<feature>/~` can. Enforced by `code-import-patterns` in `eslint.config.js`. New contrib folders under `src/vs/sessions/contrib/` must also be registered in `build/lib/i18n.resources.json`. See [agent-host-sessions-providers](docs/agent-host-sessions-providers.md#debt--gotchas) for the full entry.
- **gotcha (AHP auth contract)** — agents with `protectedResources.required: true` MUST throw `AHP_AUTH_REQUIRED` (-32007) for commands invoked before authentication, NOT return empty results. The provider-side temptation to `return []` silently breaks one-shot consumer caches. See [agent-host-protocol](docs/agent-host-protocol.md#debt--gotchas) for the rule and [copilot-agent-provider](docs/copilot-agent-provider.md#authentication-contract) / [agent-host-sessions-providers](docs/agent-host-sessions-providers.md#one-shot-_ensuresessioncache--auth-aware-eager-load) for how the renderer-side `authenticationPending` autorun retries cleanly off the throw.
- **debt (remote reconnect and transports)** — the remote protocol client now settles close/dispose request lifecycle, but full AHP reconnect/replay and transport close semantics are still open. See [agent-host-remote-protocol-client](docs/agent-host-remote-protocol-client.md#remaining-debt-candidates) and [changes/2026-04-21-agent-host-debt-and-remote-client](changes/2026-04-21-agent-host-debt-and-remote-client/summary.md).
- **debt (2026-04-21 audit backlog)** — remaining Agent Host cleanup candidates span reducers, reconnect, server reverse RPC, providers, session handler, customization sync, subscriptions, protocol mirror validation, side effects, and timing-sensitive tests. See [changes/2026-04-21-agent-host-debt-and-remote-client](changes/2026-04-21-agent-host-debt-and-remote-client/summary.md#remaining-debt-tasks-from-the-audit).
- **debt (Copilot CLI parity for selfhosting)** — Agent Host already covers the core session substrate, but still needs worktree commit/checkpoint lifecycle, richer prompt/reference attachments, shipping/PR flows, plan exit handling, MCP/client-tool parity, hook sync, and request/OTel logging before extension-host Copilot CLI parity is complete. See [copilot-agent-provider](docs/copilot-agent-provider.md#copilot-cli-parity-gaps-relevant-to-the-provider), [agent-host-session-handler](docs/agent-host-session-handler.md#request-context-and-client-tool-parity), and [changes/2026-04-21-copilot-cli-agent-host-gap-audit](changes/2026-04-21-copilot-cli-agent-host-gap-audit/summary.md).
- **debt (knowledge workflow checkout shape)** — this session hit a broken `.knowledge` symlink, then `init` produced an empty worktree under the skill directory before the link was manually repointed to the real knowledge repo. Future finalize/land work should verify the symlink target, branch, and repo contents before writing. See [changes/2026-04-21-copilot-cli-agent-host-gap-audit](changes/2026-04-21-copilot-cli-agent-host-gap-audit/summary.md#what-went-wrong-or-was-misunderstood).
- **debt (`IAgent` location convention)** — `CopilotAgent` lives at `src/vs/platform/agentHost/node/copilot/copilotAgent.ts`, which is product-specific code under product-neutral `vs/platform`. It can't move to `vs/workbench/contrib/` (the agent host server runs in its own process and can't import from workbench). When a second `IAgent` lands (e.g. Claude SDK), consider grouping providers under `src/vs/platform/agentHost/node/contrib/<vendor>/` — a small new convention since `vs/platform` doesn't have a `contrib/` precedent today. See [agent-host-topology#debt--gotchas](docs/agent-host-topology.md#debt--gotchas).

## Recent changes

The `changes/` directory contains one subfolder per significant session, named `YYYY-MM-DD-short-description/`. Browse it directly for the narrative of how the system has evolved. The most recent few entries are usually the most useful context when working on adjacent areas.

## Conventions

- **Doc scope:** one component or concern per doc, with a `Covers:` line listing the VS Code paths the doc is primarily concerned with. If the `Covers:` list doesn't fit in a sentence, the doc is too broad — split it.
- **Cross-linking:** plain Markdown relative links inline where relevant. This index is the only file that tries to be exhaustive.
- **Changelog per doc:** every doc ends with a `Changelog` section. Each entry: `**YYYY-MM-DD** — <short SHA> — <summary>`. Use a 10-character abbreviated SHA (e.g. via `git rev-parse --short=10`) — readable, and still unambiguous in practice. The most recent entry's SHA is the baseline that `reconcile` diffs against.
- **Debt & gotchas per doc:** every doc has a `## Debt & gotchas` section between the body and the changelog. Two kinds of entries, each one bullet line, dated, with the relevant file/symbol:
  - **`gotcha`** — "X is the way it is on purpose; if you touch it, do Y." Load-bearing weirdness; presumed permanent.
  - **`debt`** — "Y looks wrong / could be cleaned up / needs revisiting." Has an implicit lifetime; resolved when fixed. Example: `- **debt** (2026-04-17, agentSessionService.ts:registerProvider) — provider registration is duplicated in two code paths; should be unified once protocol v3 lands.`
- **Source of truth is the code.** When a doc and the code disagree, the code wins. Update the doc.
