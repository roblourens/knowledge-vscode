# Agent Host Topology and Protocol Philosophy

_Covers: src/vs/platform/agentHost/, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/remoteAgentHost/_

This is the **orientation doc**. It answers three questions that come up at the start of every agent-host task:

1. What *is* the Agent Host Protocol (AHP), and what is it explicitly *not*?
2. Which apps in the VS Code repo can host agents, and in which configurations?
3. Where does VS Code-specific behavior live, given the protocol is meant to be generic?

If a contribution doesn't fit cleanly into the answers below, that's a signal — it usually means the protocol is being asked to do too much, or VS Code-specific code is leaking into the wrong layer.

## 1. Protocol philosophy: AHP is generic by design

AHP is a **public, agent-agnostic protocol**. The source of truth lives in the sibling [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) repo; the generated surface is checked in under `src/vs/platform/agentHost/common/state/protocol/` (files there are marked `DO NOT EDIT`). For contract details see [agent-host-protocol](./agent-host-protocol.md).

The cardinal rule:

> **Neither the client nor the server in AHP is "VS Code." Either could be someone else's implementation.**

Concretely, an AHP server might be the local utility process we ship, a Copilot agent runtime over a tunnel, a third-party vibe-coded WebSocket server. An AHP client might be the VS Code workbench, the Agents app, a CLI, someone else's IDE. Every protocol decision must work for all four corners of that matrix.

This is why the protocol's data model is so deliberately neutral:

- Tool calls flow as `IToolCallState` with **generic display fields** (`displayName`, `invocationMessage`, `pastTenseMessage`, `toolKind`) — never as agent-specific tool names like `bash` or `view`.
- Sessions are URI-addressed with the **provider name as the URI scheme** (`copilot:/<rawId>`, `mock:/<rawId>`, etc.) — no provider-specific session shape.
- Customizations are opaque [Open Plugin](https://open-plugins.com/) refs, identified by URI; the protocol doesn't know what's inside them.
- Versioning is forward-compatible via a single protocol version + a `ProtocolCapabilities` object. Newer clients check capabilities before using features.

### The two sanctioned exceptions: well-known conventions

There are exactly two places where VS Code (and other clients) are allowed to read meaning out of otherwise-generic data, by **convention**, not by protocol:

**1. Well-known property names in generic configuration.**
Models and sessions carry a generic configuration bag. VS Code recognizes a small set of well-known property names in that bag and triggers specific UI for them. The protocol still treats the bag as opaque — only the *names* are conventions, agreed across implementations that want VS Code-friendly UI.

**2. Tool-call kinds and metadata.**
Tool calls carry a `toolKind` (e.g. `'terminal'`) and a metadata bag. VS Code uses these to decide rendering — a `toolKind: 'terminal'` call gets the syntax-highlighted command + output renderer; everything else falls through to the generic `invocationMessage` / `pastTenseMessage` renderer (see `stateToProgressAdapter.ts`). The renderer **never matches on tool name**.

These conventions live *outside* the protocol spec. They're how a generic protocol grows useful UI affordances without putting product-specific concepts into the wire format.

If you're tempted to add a third exception — stop. Almost always the right move is either (a) a new generic field on the protocol side, or (b) a new well-known convention that fits one of the two existing buckets. Adding VS Code names to the protocol itself is the failure mode.

## 2. Topology: two apps, three configurations

The VS Code repo ships **two apps** that share most of the agent-host code:

| App | Source root | Local agent host | Remote agent hosts |
|---|---|---|---|
| **VS Code** (the IDE) | `src/vs/workbench/` | ✅ yes | ❌ no |
| **Agents app** (still in `src/vs/sessions/`) | `src/vs/sessions/` | ✅ yes | ✅ yes (one or more) |

> **Naming gotcha:** the Agents app code is still rooted at `src/vs/sessions/`. The product was renamed from "Sessions" to "Agents" but the directory was not. See [`src/vs/sessions/README.md`](#) for the layer's own description ("Agentic Window"). The directory name is `sessions/`; the product is "Agents." When in doubt, search for both terms.

The layering rule between the two apps is enforced by ESLint:

```
vs/sessions  may import from  vs/workbench  ✅
vs/workbench may import from  vs/sessions   ❌  (forbidden)
```

So shared agent-host code lives under `vs/workbench` (or `vs/platform`), and the Agents app extends or composes it via its own contributions under `vs/sessions/contrib/`.

### The three configurations

```
┌──────────────────────────────────────────────────────────────────┐
│ A. VS Code + local agent host                                    │
│    [VS Code workbench] ──MessagePort── [local utility process]   │
│    AgentHostContribution registers one chat session type per     │
│    advertised agent. connectionAuthority: 'local'.               │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ B. Agents app + local agent host                                 │
│    [Agents workbench] ──MessagePort── [local utility process]    │
│    Same underlying handler/contribution code as (A); different   │
│    workbench layout (vs/sessions) and session list UI.           │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────┐
│ C. Agents app + one or more remote agent hosts                   │
│    [Agents workbench] ──WebSocket/SSH/Tunnel── [remote AHP srv]  │
│    RemoteAgentHostContribution registers one chat session type   │
│    per (remote × agent) pair. connectionAuthority: <sanitized    │
│    remote name>. Multiple remotes coexist.                       │
└──────────────────────────────────────────────────────────────────┘
```

VS Code (the IDE) gets configuration A only. The Agents app gets B and any number of C. There is no "VS Code + remote agent host" configuration today.

### The shared seam: `IAgentConnection` and `AgentHostSessionHandler`

What lets all three configurations share code is that everything above the wire is written against `IAgentConnection` (in `src/vs/platform/agentHost/common/agentService.ts`). Local and remote both satisfy it; the handler doesn't know which it has.

Both contributions construct the same `AgentHostSessionHandler` with a config like:

```typescript
new AgentHostSessionHandler({
    provider:            agent.provider,        // e.g. 'copilot'
    agentId:             sessionType,
    sessionType,                                 // 'agent-host-copilot' or
                                                 // 'remote-agent-host-<remote>-copilot'
    fullName:            agent.displayName,
    description:         agent.description,
    connection:          loggedConnection,       // IAgentConnection
    connectionAuthority: 'local' | sanitized,    // 'local' or remote name
});
```

The only differences across configurations:

- **`sessionType`** — local uses `agent-host-${provider}`; remote uses `remoteAgentHostSessionTypeId(remoteName, provider)`. This keeps each (host × agent) pair as a distinct session type in the chat sessions registry.
- **`connectionAuthority`** — used by file-system and URI services to scope which Agent Host owns a given resource URI. Local resources live under authority `'local'`; remote resources live under the sanitized remote name.
- **`connection`** — `MessagePortConnection` for local, one of the WebSocket / SSH / tunnel transports for remote.

Anything that branches on local-vs-remote *inside* the handler is a smell — push it down to the connection or up to the contribution that knows which environment it's in.

### Lifecycle controls live separately from `IAgentConnection`

`IAgentConnection` is the protocol surface (initialize, subscribe, dispatch, etc.). It is not where you ask the host to *restart* or where you start a WebSocket server. Those live on:

- `IAgentHostService` (extends `IAgentConnection`) — local-only lifecycle (restart, dev-mode startup).
- `IRemoteAgentHostService` — manages the set of configured remote entries and their connection state.
- `ISSHRemoteAgentHostService`, `ITunnelAgentHostService` — transport-specific machinery.

If a workbench feature reaches for one of these instead of `IAgentConnection`, that's deliberate (it needs lifecycle), and that feature is by definition *not* shared between local and remote.

## 3. Where to put new code

The decision tree, in order:

1. **Is it a contract change** (new state field, new action, new capability)? → It belongs in [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) first, then regenerate `state/protocol/` here. See [agent-host-protocol](./agent-host-protocol.md).
2. **Is it a new well-known convention** (property name, tool kind)? → Document it in the agent-host-protocol repo's conventions section; implement the recognition in the relevant VS Code adapter (the renderer for tool kinds; the appropriate UI for config property names). Don't put the well-known names into the protocol's TypeScript types.
3. **Does it run a turn or render session state?** → `AgentHostSessionHandler` (works in all three configurations). See [agent-host-session-handler](./agent-host-session-handler.md).
4. **Is it about *which* agents/sessions exist or how they're listed?** → A `*Contribution` (`AgentHostContribution` for local; `RemoteAgentHostContribution` for remote) and a `*SessionsProvider` (Agents app only).
5. **Is it Agents-app-only chrome** (sidebar, sessions view, titlebar widget)? → `src/vs/sessions/contrib/`.
6. **Is it local-only lifecycle** (restart, port wiring, dev mode)? → `IAgentHostService` and friends, *not* the handler.

If you can't place a piece of code in exactly one of these buckets, that's the moment to pause and re-read this doc — there's almost always a layering mistake hiding in the ambiguity.

## Related

- [agent-host-protocol](./agent-host-protocol.md) — the wire contract this doc is the philosophy for.
- [agent-host-session-handler](./agent-host-session-handler.md) — the shared handler used in all three configurations.

## Debt & gotchas

_(Empty for now. Entries take the form `- **debt|gotcha** (YYYY-MM-DD, file:symbol) — description`.)_

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP generic-protocol philosophy (neither client nor server is "VS Code"), the two sanctioned convention exceptions (well-known config property names; tool-call kinds + metadata), the two-app topology (VS Code app vs Agents app — the latter still rooted at `src/vs/sessions/`), the three deployment configurations (VS Code + local; Agents + local; Agents + remote × N), the `IAgentConnection` / `AgentHostSessionHandler` shared seam with `connectionAuthority` and `sessionType` as the only per-configuration variations, and the where-to-put-new-code decision tree.
