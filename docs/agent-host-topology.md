# Agent Host Topology and Protocol Philosophy

_Covers: src/vs/platform/agentHost/, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/remoteAgentHost/, src/vs/sessions/contrib/sessions/browser/views/sessionsList.ts, src/vs/sessions/contrib/chat/browser/scopedWorkspacePicker.ts_

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
Models and sessions carry a generic configuration bag. VS Code recognizes a small set of well-known property names in that bag and triggers specific UI for them. The protocol still treats the bag as opaque — only the *names* are conventions, agreed across implementations that want VS Code-friendly UI. Concrete example: the `autoApprove` session-config property triggers the unified permission picker — see [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) for how recognition (by enum *shape*, not name alone) and the fallback to the generic per-property picker work.

**2. Tool-call kinds and metadata.**
Tool calls carry a `toolKind` (e.g. `'terminal'`) and a metadata bag. VS Code uses these to decide rendering — a `toolKind: 'terminal'` call gets the syntax-highlighted command + output renderer; everything else falls through to the generic `invocationMessage` / `pastTenseMessage` renderer (see `stateToProgressAdapter.ts`). The renderer **never matches on tool name**.

These conventions live *outside* the protocol spec. They're how a generic protocol grows useful UI affordances without putting product-specific concepts into the wire format.

If you're tempted to add a third exception — stop. Almost always the right move is either (a) a new generic field on the protocol side, or (b) a new well-known convention that fits one of the two existing buckets. Adding VS Code names to the protocol itself is the failure mode.

### Designing for the spec and the in-tree client, not for theoretical external ones

A corollary of "neither side is VS Code" that is **not** "design for hypothetical third-party callers":

> The protocol is open; the *design target* for any concrete change is the AHP spec plus the actual in-tree client (or server) that uses it. We do **not** speculatively over-flex APIs to accommodate unknown future external callers.

When weighing two contract shapes, the weight goes to: **what does the spec mandate, and what does our concrete in-tree consumer need?** Not: "but a future external client might prefer X." If a future external client appears, *they* adapt to the spec — that's the whole point of having a spec. Optimizing for unspecified third-party callers leads to over-flexible APIs where every method takes a config bag, every error becomes an empty-result fallback, and every behavior is opt-in. That isn't generality; it's under-decided design.

Concrete example: when `CopilotAgent.listSessions()` was returning `[]` instead of throwing `AHP_AUTH_REQUIRED` on missing auth, one tempting "fix" was to make the throw-vs-empty behavior configurable so callers could choose. That would have been catering to imaginary clients; the spec says throw, our in-tree client (the renderer's `authenticationPending` autorun) handles the throw cleanly, and that's the end of the discussion. See [changes/2026-04-20-fix-initial-session-list-display](../changes/2026-04-20-fix-initial-session-list-display/summary.md) for the full reasoning.

This rule is the natural complement to the cardinal rule. "Neither side is VS Code" tells you not to bake VS Code names into the wire; **this** rule tells you not to bake hypothetical callers into the design either. The spec is the contract; both sides serve it.

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

### Remote host scoping in the Agents app

When the Agents app runs in web with remote agent hosts, the active host is also a piece of app chrome, not protocol state. `AgentHostFilterService` (`src/vs/sessions/contrib/remoteAgentHost/browser/agentHostFilterService.ts`) watches registered remote `IAgentHostSessionsProvider`s, tracks their connection statuses, persists the selected provider id, and exposes reconnect/disconnect commands. `HostFilterActionViewItem` renders that state as the titlebar host dropdown.

The selected provider id scopes Agents-app surfaces that need a single host context: `sessionsList.ts` filters the sessions list to the selected provider, and `scopedWorkspacePicker.ts` filters workspace choices to the same provider. This is deliberately above `IAgentConnection`: the protocol still sees independent remote hosts, while the app decides which host the user is currently looking at.

### The shared seam: `IAgentConnection` and `AgentHostSessionHandler`

What lets all three configurations share code is that everything above the wire is written against `IAgentConnection` (in `src/vs/platform/agentHost/common/agentService.ts`). Local and remote both satisfy it; the handler doesn't know which it has.

Both contributions construct the same `AgentHostSessionHandler` with a config like:

```typescript
new AgentHostSessionHandler({
    provider:            agent.provider,        // e.g. 'copilotcli'
    agentId:             sessionType,
    sessionType,                                 // 'agent-host-copilotcli' or
                                                 // 'remote-agent-host-<remote>-copilotcli'
    fullName:            agent.displayName,
    description:         agent.description,
    connection:          loggedConnection,       // IAgentConnection
    connectionAuthority: 'local' | sanitized,    // 'local' or remote name
});
```

The only differences across configurations:

- **`sessionType`** — local uses `agent-host-${provider}`; remote uses `remoteAgentHostSessionTypeId(remoteName, provider)`. This keeps each (host × agent) pair as a distinct session type in the chat sessions registry. Note: this is the *chat sessions registry* type — distinct from the **Sessions-app `ISession.sessionType`** (which is `agent.provider` itself, e.g. `copilotcli`, so the same agent shares one logical type across hosts). See [agent-host-sessions-providers](./agent-host-sessions-providers.md#session-type-id-vs-resource-scheme).
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
4. **Is it about *which* agents/sessions exist or how they're listed?** → Start at the provider/listing owner. SDK-backed local agents, for example, should filter or adopt sessions in the provider (`CopilotAgent.listSessions`) before generic `AgentService` aggregation or UI providers see them. Registration/list UI belongs in a `*Contribution` (`AgentHostContribution` for local; `RemoteAgentHostContribution` for remote) and a `*SessionsProvider` (Agents app only).
5. **Is it Agents-app-only chrome** (sidebar, sessions view, titlebar host filter)? → `src/vs/sessions/contrib/`.
6. **Is it local-only lifecycle** (restart, port wiring, dev mode)? → `IAgentHostService` and friends, *not* the handler.

If you can't place a piece of code in exactly one of these buckets, that's the moment to pause and re-read this doc — there's almost always a layering mistake hiding in the ambiguity.

## Related

- [agent-host-protocol](./agent-host-protocol.md) — the wire contract this doc is the philosophy for.
- [copilot-agent-provider](./copilot-agent-provider.md) — provider-level Copilot SDK session ownership and local metadata behavior.
- [agent-host-session-handler](./agent-host-session-handler.md) — the shared handler used in all three configurations.
- [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) — the concrete worked example of the well-known `autoApprove` config property convention.

## Debt & gotchas

- **gotcha** (2026-04-19, agentHostMain.ts / agentHostServerMain.ts) — the agent-host child process registers ONLY `INativeEnvironmentService`, not `IEnvironmentService` (the base token). All consumers in the child process use the native token. The parent-process starter (`nodeAgentHostStarter.ts`) runs in the main Electron process's DI container and does use `IEnvironmentService`, but that's a different container — don't confuse the two. Other VS Code processes may register both tokens; the agent host is native-only.
- **gotcha** (2026-04-22, RemoteAgentHostService.IConnectionEntry.store) — the per-entry `DisposableStore` on each connection entry is THE entry-lifetime ownership boundary. Anything that must be torn down when the user clicks "Remove Remote", when config-driven reconciliation drops an entry, or when the service itself is disposed, MUST be registered there. The `addManagedConnection({ ... }, protocolClient, transportDisposable?)` API is how the SSH/tunnel renderers hand transport-level cleanup into that store. New entry-scoped resources should follow the same pattern — do NOT register them on the renderer service itself, or they'll outlive the entry.
- **gotcha** (2026-04-22, *RelayTransport.dispose) — relay-transport `dispose()` implementations are responsible for telling the shared-process side to close the underlying connection. `TunnelRelayTransport.dispose()` and `TunnelConnectionTransport.dispose()` both do this; `SSHRelayTransport.dispose()` historically did NOT (it only removed IPC listeners), which is why removing an SSH-backed remote leaked the tunnel until the SSH renderer started passing its own `transportDisposable` that calls `_mainService.disconnect(connectionId)`. If you add a new relay transport, make sure its `dispose()` either closes the shared-process connection itself or that the renderer that owns it passes a `transportDisposable` that does.

## Changelog

- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP generic-protocol philosophy (neither client nor server is "VS Code"), the two sanctioned convention exceptions (well-known config property names; tool-call kinds + metadata), the two-app topology (VS Code app vs Agents app — the latter still rooted at `src/vs/sessions/`), the three deployment configurations (VS Code + local; Agents + local; Agents + remote × N), the `IAgentConnection` / `AgentHostSessionHandler` shared seam with `connectionAuthority` and `sessionType` as the only per-configuration variations, and the where-to-put-new-code decision tree.
- **2026-04-17** — `9364e338cc` — clarified that SDK-backed providers own session filtering/adoption boundaries before generic aggregation or UI listing.
- **2026-04-19** — `bea3e7e018` — added gotcha: agent-host child process registers only `INativeEnvironmentService`, not the base `IEnvironmentService` token.
- **2026-04-20** — `d05eca7455` — added "Designing for the spec and the in-tree client, not for theoretical external ones" as a corollary to the cardinal rule. Captures the principle that we do not over-flex APIs to accommodate hypothetical future external callers — the spec is the contract and the in-tree consumer is the design target.
- **2026-04-20** — `7f8e7e0f0c` — added the `autoApprove` session-config property as a concrete worked example of well-known convention #1, with a pointer to the new [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) doc.
- **2026-04-20** — `00f882a16c` — renamed `CopilotAgent.id` from `'copilot'` to `'copilotcli'` (the agent now advertises itself with the same name the UI uses for it). Updated example values in the `IAgentHostSessionHandlerConfig` snippet and clarified that the chat-sessions-registry `sessionType` is distinct from the Sessions-app `ISession.sessionType` (which is `agent.provider` directly, so the same agent shares one logical type across local and remote). See [agent-host-sessions-providers#session-type-id-vs-resource-scheme](./agent-host-sessions-providers.md#session-type-id-vs-resource-scheme).
- **2026-04-18** — `73bca3fa35` — reconciliation: no doc changes. `6f22a555943` (session-config restore) is already covered at finer grain by `agent-host-session-handler.md` and `agent-host-sessions-providers.md`; `e831da2ef96` flipped the `RemoteAgentHostsEnabledSettingId` and `AgentHostIpcLoggingSettingId` defaults from `=== 'insider'` / `false` to `!== 'stable'` — setting-default tweak that doesn't affect topology-level concepts.
- **2026-04-21** — `ad531180d0` — reconciliation: added the Agents-app remote host filter/scoping layer from `04d051144b0`; `a1abedfea06`, `0a84983bc1e`, `6994450cd36`, and `2e33f3dc7b3` touched agent-host implementation details already covered by narrower docs or not relevant to topology.
- **2026-04-22** — `e559871236` — added two gotchas for the connection-entry lifecycle: the per-entry `DisposableStore` is the canonical entry-lifetime boundary (use the renamed `addManagedConnection({...}, client, transportDisposable?)` API to hand transport teardown into it), and relay-transport `dispose()` implementations are responsible for closing the shared-process connection. Surfaced after fixing an SSH "Remove Remote" leak where neither layer was tearing the tunnel down.
