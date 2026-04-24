# Agent Host Topology and Protocol Philosophy

_Covers: src/vs/platform/agentHost/, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/remoteAgentHost/, src/vs/sessions/contrib/sessions/browser/views/sessionsList.ts, src/vs/sessions/contrib/chat/browser/scopedWorkspacePicker.ts_

This is the **orientation doc**. It answers four questions that come up at the start of every agent-host task:

0. What is the *defining property* of the system that everything else falls out of?
1. What *is* the Agent Host Protocol (AHP), and what is it explicitly *not*?
2. Which apps in the VS Code repo can host agents, and in which configurations?
3. Where does VS Code-specific behavior live, given the protocol is meant to be generic?

If a contribution doesn't fit cleanly into the answers below, that's a signal — it usually means the protocol is being asked to do too much, or VS Code-specific code is leaking into the wrong layer.

## 0. The defining property: agent-autonomous, client-optional

> **The agent runs without a client. The client is a viewer/controller that comes and goes.**

This is the single most load-bearing fact about the system. Internalize it before everything else; the rest of this doc, the protocol design, the persistence model, the reconnect/replay machinery, and the file-edit topology all fall out of it.

Concretely:

- The agent host server is a long-lived process that keeps making progress whether or not any client is connected.
- Sessions can be created, run turns, finish, and be ended without a client involved.
- The server is the source of truth for AHP-side state precisely because clients come and go.
- File edits land where the agent runs, never where the client is. The agent's correctness can't depend on a client being there to apply something.
- Auth must be expressible without a client present (the agent declares it needs auth; some client *eventually* provides it; work continues independently).

Multi-client correctness — N clients observing the same session — is a *corollary* of this property, not the primary motivation. We need a server-of-truth + replay model anyway because clients are optional; once you have it, multi-client falls out for free.

## AHP vs ACP — different problems on different axes

The sibling [`agent-host-protocol`](https://github.com/microsoft/agent-host-protocol) repo has a dedicated doc on this: [docs/guide/ahp-and-acp.md](https://github.com/microsoft/agent-host-protocol/blob/main/docs/guide/ahp-and-acp.md). The short version:

- **ACP** (Agent Client Protocol) is a 1:1 communication protocol between a single client and a single agent.
- **AHP** is a coordination layer for **N clients sharing a host that hosts agents**. The host is the source of truth; clients reconcile.

They compose: an AHP host *could* speak ACP downstream to agents. We don't do that today — our in-tree first-party agents (Copilot today, Claude planned) sit alongside `CopilotAgent` as in-process `IAgent` implementations using vendor SDKs directly. The host/agent layering is **collapsed in-process by design** for first-party agents.

A future ACP bridge — `class AcpAgent implements IAgent` — is reserved for *external* agents that already speak ACP. It is not the eventual home for our own agents. New first-party agents follow the `CopilotAgent` shape.

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

### A non-exception: interop with other vendor-neutral specs

Distinct from the two convention exceptions above, AHP also **interops with other vendor-neutral specs** by carrying opaque references into them. The current example is **customizations**, which are [Open Plugin](https://open-plugins.com/) refs identified by URI. Open Plugin is a multi-vendor standard (not a VS Code construct), so AHP referencing it is not VS Code-flavoring the protocol — it's standardizing on a separate cross-app convention for what a customization ref means.

This is structurally different from the two well-known exceptions: those are conventions *we* define on top of generic AHP fields; interop refs are pointers into specs *other people* define. AHP knows nothing about what's behind the URI; the agent fetches and applies it. If other vendor-neutral specs appear (a tool spec, a model registry, etc.), they fit the same shape: opaque refs in AHP, resolution by the agent.

### State + reducers is for session/agent state — not for everything

The state-tree-and-reducers model that AHP is famous for is the model for **session and agent state**: things multiple clients need to observe, replay after reconnect, or apply optimistically. It is **not** the model for everything in the protocol.

Operations that are independent of session state — filesystem reads/writes, terminal management, and similar service-style RPCs — are plain commands, not actions through reducers. The two patterns coexist by design:

- **Reducers** apply where multi-client observation, replay, and optimistic UI matter (anything in the session/root state tree).
- **Commands** apply where you just need to ask the server to do something and get a result (filesystem ops, lifecycle calls, etc.).

If you find yourself trying to design a reducer for `readFile`, you're in the wrong pattern. If you find yourself trying to call a command for "agent emitted a delta," same. The boundary between the two is a deliberate part of the protocol shape.

### Greenfield, not back-compat

The protocol is in active design. **Right now we prefer breaking changes over preserving compat.** `ProtocolCapabilities` exists as scaffolding for the future — it is not a current design constraint. Premature back-compat would distort decisions while we're still figuring out the right shape.

This is a deliberate posture, not laziness. Once the protocol stabilizes, we'll switch modes; until then, treat "this would break older clients/servers" as a non-objection in design discussions.

### Designing for the spec and the in-tree client, not for theoretical external ones

A corollary of "neither side is VS Code" that is **not** "design for hypothetical third-party callers":

> The protocol is open; the *design target* for any concrete change is the AHP spec plus the actual in-tree client (or server) that uses it. We do **not** speculatively over-flex APIs to accommodate unknown future external callers.

When weighing two contract shapes, the weight goes to: **what does the spec mandate, and what does our concrete in-tree consumer need?** Not: "but a future external client might prefer X." If a future external client appears, *they* adapt to the spec — that's the whole point of having a spec. Optimizing for unspecified third-party callers leads to over-flexible APIs where every method takes a config bag, every error becomes an empty-result fallback, and every behavior is opt-in. That isn't generality; it's under-decided design.

Concrete example: when `CopilotAgent.listSessions()` was returning `[]` instead of throwing `AHP_AUTH_REQUIRED` on missing auth, one tempting "fix" was to make the throw-vs-empty behavior configurable so callers could choose. That would have been catering to imaginary clients; the spec says throw, our in-tree client (the renderer's `authenticationPending` autorun) handles the throw cleanly, and that's the end of the discussion. See [changes/2026-04-20-fix-initial-session-list-display](../changes/2026-04-20-fix-initial-session-list-display/summary.md) for the full reasoning.

This rule is the natural complement to the cardinal rule. "Neither side is VS Code" tells you not to bake VS Code names into the wire; **this** rule tells you not to bake hypothetical callers into the design either. The spec is the contract; both sides serve it.

## 2. Topology: two apps, two deployment shells, three configurations

Before the apps and configurations, there are two **axes of code sharing** to keep straight:

1. **Server side vs. client side.** Server-side code (everything under `src/vs/platform/agentHost/node/`, plus what runs *inside* the agent host process — `IAgent` implementations, `AgentService`, transports, persistence) is **inherently shared**. Neither "the IDE" nor "the Agents app" exists at this layer; the server is just the AHP host.
2. **For client-side code, who consumes it.** Client-side code splits into VS Code-specific (`vs/workbench/contrib/...`), Agents-app-specific (`vs/sessions/contrib/...`), and shared (`vs/workbench` or `vs/platform`, consumed by both).

The two-pickers example in [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) is *not* duplicated UI — it's two distinct client-side surfaces (workbench chat input toolbar vs. Agents-app new-chat page) sharing a model-layer delegate. Expect more of this pattern, not less. Trying to unify the views would produce a worse abstraction than the duplication; the shared delegate is the seam that matters.

### Deployment shells

The server-side code has **two entry points** today, each a different deployment shell:

| Entry point | Transport | Spawned by | Lifecycle owner |
|---|---|---|---|
| `src/vs/platform/agentHost/node/agentHostMain.ts` | MessagePort over utility-process IPC | VS Code / Agents app main process | Workbench (parent process) |
| `src/vs/platform/agentHost/node/agentHostServerMain.ts` | WebSocket | A launcher (tunnel, SSH wrapper, dev script) | The launcher / SIGTERM |

When reading code, identify which shell it runs in — it determines transport, lifecycle, signal handling, and whether the parent process even exists.

### The apps

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

### Client-side authentication flow

Each `*Contribution` class (`AgentHostContribution` for local, `RemoteAgentHostContribution` for remote) drives the `authenticate` RPC toward the connected agent host whenever auth state changes. There are **three re-auth triggers**:

1. **`rootState.onDidChange`** — fires whenever a new snapshot, optimistic write, reconcile, or `applyAction` lands (i.e., on every protocol action). This is the source of the `[Copilot] Auth token unchanged` log spam if client-side dedupe is absent.
2. **`IAuthenticationService.onDidChangeSessions`** — fires for *any* auth provider, not just GitHub. A Google or Microsoft sign-in would also trigger a Copilot re-auth.
3. **`IAuthenticationService.onDidChangeDefaultAccount`** — narrowed to GitHub by the subscription filter; fires when the user's active GitHub account changes.

The `AgentHostAuthTokenCache` class (`agentHostAuth.ts`) provides per-resource token dedupe: `updateAndIsChanged(resource, token)` returns `false` if the token is unchanged, and `clear(resource?)` evicts one entry or the whole cache. The `_authenticateWithServer` / `_authenticateWithConnection` methods call `updateAndIsChanged` first; if unchanged they return early.

**Cache lifecycle rules** (all three must hold):

- **Seed the cache *after* the RPC, not before.** If `authenticate()` throws, call `cache.clear(resource)` so the next attempt is not suppressed.
- **Clear per-resource on RPC failure.** A failed `authenticate` should not leave a stale "seen this token" entry.
- **Clear the whole cache on `onAgentHostStart`.** The local agent host process can die and restart; its in-memory auth state is erased. The cache must be invalidated so the next `_authenticateWithServer` call re-sends the token even though it is numerically unchanged.

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
6. **Is it host-level or per-session configuration** (a new well-known config key, a new way to view or edit values)? → The platform-side schema + key list lives in `src/vs/platform/agentHost/common/sessionConfigKeys.ts` and `agentHostSchema.ts`; server-side `session → parent subagent → host` resolution lives in `src/vs/platform/agentHost/node/agentConfigurationService.ts` (`IAgentConfigurationService.getEffectiveValue`); UI editors for the synthetic per-session and host-level JSONC files live in `src/vs/sessions/contrib/agentHost/browser/agentSessionSettings.contribution.ts` and `agentHostSettings.contribution.ts`. See [agent-host-sessions-providers](./agent-host-sessions-providers.md#settings-editor-file-system-providers).
7. **Is it local-only lifecycle** (restart, port wiring, dev mode)? → `IAgentHostService` and friends, *not* the handler.

If you can't place a piece of code in exactly one of these buckets, that's the moment to pause and re-read this doc — there's almost always a layering mistake hiding in the ambiguity.

## 4. Semantics: sessions, persistence, auth, customizations

A handful of foundational facts about how the system actually behaves at runtime. Skipping these is a frequent source of confusion when reading the code.

### Persistence is split: agent owns chat data, host owns metadata

The agent backend (Copilot SDK today, Claude SDK planned) **owns the actual session data** — the chat history, messages, agent working memory. That lives wherever the SDK stores it, and is durably written by the SDK at the moment it's generated.

The agent host **owns an augmenting metadata layer** in per-session SQLite databases under the host's `userDataPath` (see `SessionDataService`). This layer holds things AHP-side that the SDK doesn't know about: custom titles, `isRead`/`isDone` flags, `configValues`, diffs, etc.

Two persistence stores per session, with different ownership and durability properties:

- The agent SDK store is the **source of truth for chat content**. If lost, chat history is gone.
- The metadata DB **augments** the SDK store. It is *not* rebuildable from SDK data — it's an independent record of host-side decisions.

The shutdown path in `agentHostServerMain.ts` deliberately flushes `sessionDataService.whenIdle()` before disposing, because losing in-flight metadata writes (like a `setMetadata` call carrying the latest `configValues`) breaks the "Session Config persistence across restarts" contract. That flush is load-bearing — see the doc's `## Debt & gotchas` for the gotcha entry.

### The database-existence ownership gate

The Copilot SDK can report sessions that *this* AHP host did not create (e.g. sessions made by other Copilot tools using the same auth, or by a previous AHP install). The provider (`CopilotAgent.listSessions`) filters those out: **only sessions for which we have a metadata DB entry are surfaced as "ours."**

This is intentional and firm:

- Cross-tool session sharing is **out of scope**. AHP is not trying to be a universal viewer of every Copilot session ever; it's a host for sessions it manages.
- If the metadata DB is lost (disk wipe, fresh install, corruption), the underlying SDK sessions still exist but are orphaned from AHP's perspective. Recovery is via other Copilot tools, not via AHP.
- If pressure ever arrives to relax the gate, the path is **degrade gracefully without metadata**, not rebuild metadata. Don't design for that today.

### AHP sessions ≠ SDK sessions

A "session" in AHP is an **AHP-level abstraction for a unit of work the host can address, observe, and route actions to**. It is not a 1:1 mapping to anything in the agent backend.

The canonical example: **subagents are first-class AHP sessions, but are *not* separate SDK sessions.** Structuring them as AHP sessions gives uniform host/client treatment of lifecycle, state, subscriptions, and UI \u2014 even though the underlying agent doesn't model them as separate sessions.

The mapping between AHP sessions and SDK sessions is the **agent provider's job**. New providers don't need to (and shouldn't) preserve a 1:1 mapping if the host-side abstraction benefits from a richer one.

This is an instance of a broader principle: **protocol-level uniformity beats SDK-side structural fidelity.** Model things uniformly at the protocol layer; let the provider translate to whatever the SDK actually does underneath.

### Workspace lives where the agent runs

In configuration C (Agents app + remote agent host), file edits land on the **remote machine**, not on the client. The agent is self-contained and acts on the workspace it sits next to; the client is a viewer/controller that observes via state actions and accesses files through the `AGENT_CLIENT_SCHEME` virtual filesystem provider proxy.

Worktrees, checkpoints, diffs, and any other workspace-bound state all live on the agent's side. The client never holds the authoritative copy.

This is a direct consequence of section 0: an agent that runs without a client cannot apply edits *via* a client.

### Auth: a four-layer division of labor

Auth is split across four layers, and each layer is ignorant of the others:

| Layer | Owns |
|---|---|
| Agent SDK (Copilot, Claude, ...) | Token storage, refresh, OAuth dance, browser/dialog UI |
| Agent host (provider) | Surfacing \"we need auth\" via `AHP_AUTH_REQUIRED` (-32007) |
| AHP renderer client | Orchestrating the retry-after-auth loop via `authenticationPending` autorun |
| Workbench / Agents-app UI | Showing the user the auth prompt (when not handled by the SDK directly) |

The protocol's `protectedResources.required: true` + `AHP_AUTH_REQUIRED` throw is the **only contract** between the agent host and the renderer client \u2014 everything above it can be agent-agnostic, everything below it can be client-agnostic. New `IAgent` implementations (Claude, etc.) plug into the same mechanism without per-agent customization in the host.

The provider-side temptation to `return []` instead of throwing on missing auth silently breaks the renderer's one-shot caches. Throw the error; let the autorun retry.

## Principles

A short list of the values that drive design decisions in the agent host. When in doubt, weigh changes against these.

1. **Generic by construction.** Neither side of AHP is \"VS Code.\" Bake nothing product-specific into the wire. Use well-known conventions for two narrow exceptions; interop with vendor-neutral specs (Open Plugin) for everything else.\n2. **Design for the spec and the in-tree consumer; not for hypothetical third parties.** Generality lives in the spec, not in over-flexed APIs.\n3. **Greenfield velocity over back-compat.** Right now, breaking changes are *preferred*. Premature back-compat distorts the design.\n4. **Agent-autonomous, client-optional.** The agent does its own work; the client comes and goes. Everything else falls out of this.\n5. **State + reducers + `serverSeq` is the model for session/agent state \u2014 not for everything.** Service-style RPCs (filesystem, lifecycle) are plain commands. Don't conflate the two patterns.\n6. **Protocol-level uniformity beats SDK-side structural fidelity.** Subagents-as-sessions is the canonical example.\n7. **Layering over collapsing.** Two apps, one server runtime, multiple deployment shells, sharp ESLint-enforced import rules. Don't merge layers to save typing.\n8. **Pragmatism over purity.** Where layering doesn't actually buy something, accept the slight smell rather than refactor for principle's sake. Mark as debt if material; otherwise leave.\n\n## Related

- [agent-host-protocol](./agent-host-protocol.md) — the wire contract this doc is the philosophy for.
- [copilot-agent-provider](./copilot-agent-provider.md) — provider-level Copilot SDK session ownership and local metadata behavior.
- [agent-host-session-handler](./agent-host-session-handler.md) — the shared handler used in all three configurations.
- [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) — the concrete worked example of the well-known `autoApprove` config property convention.

## Debt & gotchas

- **gotcha** (2026-04-23, agentHostServerMain.ts:shutdown) — the shutdown path closes `wsServer` first, then awaits `sessionDataService.whenIdle()` (capped at 3s) before disposing. This is load-bearing: a `setMetadata` write in flight when SIGTERM arrives can drop the latest `configValues`/`customTitle`/`isRead`/`isDone`/`diffs` value, which the "Session Config persistence across restarts" integration test guards against. Don't "clean up" by removing the flush or shrinking the timeout casually — reorder only with the same per-session-DB flush guarantee in mind.
- **gotcha** (2026-04-23, copilotAgent.ts:listSessions database-existence gate) — the provider intentionally filters SDK-reported sessions down to only those with a metadata DB entry. The metadata DB is **not** rebuildable from SDK data; it's an independent record of host-side decisions. Don't relax the gate to "show everything the SDK knows about" without an explicit design conversation — the answer there is degrade-without-metadata, not rebuild-from-SDK.
- **debt** (2026-04-23, src/vs/platform/agentHost/node/copilot/copilotAgent.ts) — `CopilotAgent` is product-specific code under `vs/platform`, which by VS Code convention is meant to be product-neutral. It can't move to `vs/workbench/contrib/` (the agent host server runs in its own process and can't import from workbench). The pragmatic home, when a second `IAgent` lands (e.g. Claude), is `src/vs/platform/agentHost/node/contrib/<vendor>/...` — mirroring the workbench `contrib/` convention to mark provider-specific code, even though `vs/platform` doesn't have a precedent for it. Today's location is fine; revisit if/when a second `IAgent` arrives.
- **gotcha** (2026-04-22, agentHostChatContribution.ts:_authenticateWithServer / remoteAgentHost.contribution.ts:_authenticateWithConnection) — `RootStateSubscription.onDidChange` fires on **every** applied action (snapshot, optimistic, reconcile, applyAction), not only when `protectedResources` changes. Any handler wired to `rootState.onDidChange` that issues a network call or expensive work must dedupe that work on its own — never assume the event fires only on meaningful value changes.
- **gotcha** (2026-04-22, agentHostAuth.ts:AgentHostAuthTokenCache) — the token cache must be seeded **after** the `authenticate()` RPC succeeds, never before. If seeded before, a transient RPC failure poisons the cache entry and suppresses all future retries. On any throw, call `cache.clear(resource)` to evict the entry. Additionally, the whole cache must be cleared on `onAgentHostStart` because the agent host process can restart and lose its in-memory auth state even while the client token is numerically unchanged.
- **gotcha** (2026-04-19, agentHostMain.ts / agentHostServerMain.ts) — the agent-host child process registers ONLY `INativeEnvironmentService`, not `IEnvironmentService` (the base token). All consumers in the child process use the native token. The parent-process starter (`nodeAgentHostStarter.ts`) runs in the main Electron process's DI container and does use `IEnvironmentService`, but that's a different container — don't confuse the two. Other VS Code processes may register both tokens; the agent host is native-only.
- **gotcha** (2026-04-22, RemoteAgentHostService.IConnectionEntry.store) — the per-entry `DisposableStore` on each connection entry is THE entry-lifetime ownership boundary. Anything that must be torn down when the user clicks "Remove Remote", when config-driven reconciliation drops an entry, or when the service itself is disposed, MUST be registered there. The `addManagedConnection({ ... }, protocolClient, transportDisposable?)` API is how the SSH/tunnel renderers hand transport-level cleanup into that store. New entry-scoped resources should follow the same pattern — do NOT register them on the renderer service itself, or they'll outlive the entry.
- **gotcha** (2026-04-22, *RelayTransport.dispose) — relay-transport `dispose()` implementations are responsible for telling the shared-process side to close the underlying connection. `TunnelRelayTransport.dispose()` and `TunnelConnectionTransport.dispose()` both do this; `SSHRelayTransport.dispose()` historically did NOT (it only removed IPC listeners), which is why removing an SSH-backed remote leaked the tunnel until the SSH renderer started passing its own `transportDisposable` that calls `_mainService.disconnect(connectionId)`. If you add a new relay transport, make sure its `dispose()` either closes the shared-process connection itself or that the renderer that owns it passes a `transportDisposable` that does.

## Changelog

- **2026-04-23** — `f32a933746` — substantial expansion from a grilling/values session. Added section 0 ("agent-autonomous, client-optional" as the defining property), an AHP-vs-ACP framing pointing at the sibling repo's `docs/guide/ahp-and-acp.md`, the state-vs-commands distinction within the protocol, the greenfield/no-back-compat posture, the server-side-vs-client-side sharing axis, the two deployment shells (`agentHostMain.ts` utility process; `agentHostServerMain.ts` standalone WebSocket server), section 4 ("Semantics") covering the agent/host persistence split, the database-existence ownership gate, AHP-sessions ≠ SDK-sessions (subagents example), workspace-lives-where-the-agent-runs, and the four-layer auth division of labor. Added a Principles section summarizing the eight design values. Added a non-exception category for interop with vendor-neutral specs (Open Plugin). Added gotchas for the shutdown flush and the database-existence ownership gate, and a debt entry for the `CopilotAgent` location / future `contrib/<vendor>/` convention.
- **2026-04-22** — `67763f6b5e` — added "Client-side authentication flow" subsection: the three re-auth triggers (`rootState.onDidChange`, `onDidChangeSessions`, `onDidChangeDefaultAccount`), the `AgentHostAuthTokenCache` dedupe pattern, and the three cache lifecycle rules (seed after RPC, clear on failure, clear on restart). Added two gotchas: `onDidChange` fires on every action, and cache must be seeded after the RPC not before.
- **2026-04-16** — `6cd94ddc6f` — initial entry. Captures the AHP generic-protocol philosophy (neither client nor server is "VS Code"), the two sanctioned convention exceptions (well-known config property names; tool-call kinds + metadata), the two-app topology (VS Code app vs Agents app — the latter still rooted at `src/vs/sessions/`), the three deployment configurations (VS Code + local; Agents + local; Agents + remote × N), the `IAgentConnection` / `AgentHostSessionHandler` shared seam with `connectionAuthority` and `sessionType` as the only per-configuration variations, and the where-to-put-new-code decision tree.
- **2026-04-17** — `9364e338cc` — clarified that SDK-backed providers own session filtering/adoption boundaries before generic aggregation or UI listing.
- **2026-04-19** — `bea3e7e018` — added gotcha: agent-host child process registers only `INativeEnvironmentService`, not the base `IEnvironmentService` token.
- **2026-04-20** — `d05eca7455` — added "Designing for the spec and the in-tree client, not for theoretical external ones" as a corollary to the cardinal rule. Captures the principle that we do not over-flex APIs to accommodate hypothetical future external callers — the spec is the contract and the in-tree consumer is the design target.
- **2026-04-20** — `7f8e7e0f0c` — added the `autoApprove` session-config property as a concrete worked example of well-known convention #1, with a pointer to the new [agent-host-auto-approve-picker](./agent-host-auto-approve-picker.md) doc.
- **2026-04-20** — `00f882a16c` — renamed `CopilotAgent.id` from `'copilot'` to `'copilotcli'` (the agent now advertises itself with the same name the UI uses for it). Updated example values in the `IAgentHostSessionHandlerConfig` snippet and clarified that the chat-sessions-registry `sessionType` is distinct from the Sessions-app `ISession.sessionType` (which is `agent.provider` directly, so the same agent shares one logical type across local and remote). See [agent-host-sessions-providers#session-type-id-vs-resource-scheme](./agent-host-sessions-providers.md#session-type-id-vs-resource-scheme).
- **2026-04-18** — `73bca3fa35` — reconciliation: no doc changes. `6f22a555943` (session-config restore) is already covered at finer grain by `agent-host-session-handler.md` and `agent-host-sessions-providers.md`; `e831da2ef96` flipped the `RemoteAgentHostsEnabledSettingId` and `AgentHostIpcLoggingSettingId` defaults from `=== 'insider'` / `false` to `!== 'stable'` — setting-default tweak that doesn't affect topology-level concepts.
- **2026-04-21** — `ad531180d0` — reconciliation: added the Agents-app remote host filter/scoping layer from `04d051144b0`; `a1abedfea06`, `0a84983bc1e`, `6994450cd36`, and `2e33f3dc7b3` touched agent-host implementation details already covered by narrower docs or not relevant to topology.
- **2026-04-24** — `5407371c47` — reconciliation: added a new bullet to the where-to-put-new-code decision tree for host-level / per-session configuration — platform-side keys in `sessionConfigKeys.ts` / `agentHostSchema.ts`, server-side resolution in `IAgentConfigurationService.getEffectiveValue`, and synthetic-file editors in `agentSessionSettings.contribution.ts` / `agentHostSettings.contribution.ts` (commits `779b23b6196`, `1453f5b4e9b`, `2289e091159`). The shell-env (`f158e93d346`), AH-terminal-default-off-for-local (`b6e9f6e830e`), debug-process command (`5daa98185c7`), customizations-view distinction (`1a25e306b34`), workspace-picker-UX/Manage-submenu (`d8390482c0c`/`c3afbbfc6ea`), and SSH agent-forwarding/default-identity-files (`515c4fb946d`/`f81f6515f96`) commits all land inside concepts the topology doc already describes — no prose change needed.
- **2026-04-22** — `e559871236` — added two gotchas for the connection-entry lifecycle: the per-entry `DisposableStore` is the canonical entry-lifetime boundary (use the renamed `addManagedConnection({...}, client, transportDisposable?)` API to hand transport teardown into it), and relay-transport `dispose()` implementations are responsible for closing the shared-process connection. Surfaced after fixing an SSH "Remove Remote" leak where neither layer was tearing the tunnel down.
