# Grilling session: topology, semantics, and design principles

**Date:** 2026-04-23
**VS Code SHA at write time:** `f32a933746`
**Touched docs:** `docs/agent-host-topology.md`, `index.md`

## Context

A grilling session (`.agents/skills/grill-me`) aimed at improving the *unwritten* context in the knowledge base — design decisions, values, and mental models that an experienced contributor carries in their head but a doc-only reader wouldn't extract from the existing component docs. The goal was not to document new code; it was to surface the *why* behind existing code so that future agents and contributors don't have to rediscover it.

Fifteen rounds of one-question-at-a-time grilling produced a set of net-new framings, several corrections to assumptions a careful doc reader would form, and one foundational property that was completely absent from the docs.

## Net-new facts and framings captured

1. **Agent-autonomous, client-optional** is the defining property of the system — *the* most load-bearing fact. The agent runs without a client; clients are viewers/controllers that come and go. Everything else (long-lived host process, state+reducers+`serverSeq`, server-of-truth persistence, file-edits-where-the-agent-runs, multi-client correctness) falls out of this. Now sits at the top of the topology doc as section 0.
2. **AHP vs ACP framing.** AHP is a coordination layer for N clients sharing a host; ACP is 1:1 communication between client and agent. They compose. Our first-party agents (Copilot today, Claude planned) sit collapsed in-process as `IAgent` implementations using vendor SDKs directly — this is **permanent for first-party agents**, not transitional. A future ACP bridge (`AcpAgent implements IAgent`) is reserved for *external* agents.
3. **Greenfield, not back-compat.** The protocol is in active design and breaking changes are *preferred* over preserving compat. `ProtocolCapabilities` exists as scaffolding for later, not as a current design constraint. This is a deliberate posture — premature back-compat would distort the design. Important correction to what a careful reader of the existing protocol doc would assume.
4. **Persistence split.** The agent SDK owns the actual chat/session data. The agent host owns an *augmenting metadata layer* in per-session SQLite DBs (custom titles, `isRead`/`isDone`, `configValues`, diffs). Two persistence stores per session, with different ownership and durability properties. The metadata DB is **not rebuildable** from SDK data.
5. **Database-existence ownership gate** is intentional and firm. AHP only surfaces sessions for which it has a metadata DB entry. Cross-tool session sharing is out of scope. If pressure ever arrives, the path is *degrade gracefully without metadata*, not *rebuild metadata*.
6. **AHP sessions ≠ SDK sessions.** Subagents are first-class AHP sessions but are *not* separate SDK sessions. Protocol-level uniformity beats SDK-side structural fidelity.
7. **Workspace lives where the agent runs.** In remote configurations, file edits land on the remote machine; the client is a viewer via `AGENT_CLIENT_SCHEME`. Direct consequence of (1).
8. **Auth is a four-layer division of labor.** SDK owns auth machinery; agent host passes through `AHP_AUTH_REQUIRED`; renderer client orchestrates retry; UI shows the prompt. The protocol error throw is the only contract between layers; works the same for all future agents.
9. **State + reducers is for *session/agent state* only — not for everything.** Filesystem and similar service-style RPCs are plain commands. The two patterns coexist by design. Important correction; without it someone goes looking for a reducer for `readFile`.
10. **Server vs. client sharing axis.** Server-side code (under `agentHost/node/`) is inherently shared. Client-side splits into VS Code-specific (`vs/workbench/contrib/`), Agents-app-specific (`vs/sessions/contrib/`), and shared. The two-pickers example is *not* duplicated UI — it's two different surfaces sharing a delegate.
11. **Two deployment shells.** `agentHostMain.ts` (utility process, MessagePort) and `agentHostServerMain.ts` (standalone WebSocket server). Identifying which shell code runs in determines transport, lifecycle, and signal handling.
12. **`MockAgent` is dev-only and gated** behind `--enable-mock-agent`. Not a reference for new agents — pattern off `CopilotAgent`.
13. **Open Plugin is a vendor-neutral spec, not a VS Code construct.** AHP referencing it via opaque URIs is a *third* category beyond the "two sanctioned exceptions" — it's interop with a separate cross-app standard, not a convention we made up. If other vendor-neutral specs appear, they fit the same shape.
14. **Eight Principles** consolidating the values discussion: generic by construction; design for the spec and the in-tree consumer; greenfield velocity over back-compat; agent-autonomous; state+reducers for session state but commands for service RPCs; protocol-level uniformity over SDK fidelity; layering over collapsing; pragmatism over purity.
15. **Debt note on `CopilotAgent` location.** Product-specific code under product-neutral `vs/platform`. Can't move to `vs/workbench/contrib/` (process boundary). When a second `IAgent` arrives, consider grouping under `agentHost/node/contrib/<vendor>/` — small new convention.

## Mistakes I made during the session (worth recording)

- **Hallucinated `IAgentProvider`.** The actual interface is `IAgent`, registered via `agentService.registerProvider(provider: IAgent)`. Caught immediately by the user. Reminder for future sessions: when invoking unfamiliar named seams, grep first.
- **Initially framed AHP/ACP as "different streaming-vs-state shapes for the same problem."** It's actually different problems on different axes (coordination vs. communication). Corrected by user pointing at the sibling repo's `ahp-and-acp.md` doc — which is *exactly* the kind of cross-repo context the in-tree knowledge base wasn't yet linking to.
- **Initially conflated "agent host code" with "client-side agent-host integration"** when discussing layering between the two apps. The right framing is two axes (server-vs-client; for client code, who consumes it).
- **Got persistence ownership initially wrong** — said "the agent host server owns persistence" without distinguishing the SDK-owned chat data from the host-owned metadata layer.
- **Multi-client correctness was the first benefit I named for state+reducers.** It's actually a corollary of agent-autonomous/client-optional, not the primary motivation. The session reordered this.

These are exactly the kinds of mistakes a knowledge-base-only reader would make, which is the signal that the additions land in the right place.

## What did NOT change

- No code changes in `vscode/`. Pure docs.
- No changes to component-level docs other than `topology.md` and `index.md`.
- The decision tree in section 3 of `topology.md` is unchanged.
- The existing client-side authentication flow section is unchanged.

(Written by Copilot)
