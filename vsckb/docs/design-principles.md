# Agent Host design principles

_Covers: src/vs/platform/agentHost/, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/, src/vs/sessions/contrib/agentHost/, src/vs/sessions/contrib/remoteAgentHost/, extensions/copilot/src/extension/chatSessions/copilotcli/, extensions/copilot/src/extension/conversation/vscode-node/chatParticipants.ts, extensions/copilot/src/platform/chat/common/chatAgents.ts_

These principles bias future agents when the code, docs, and current implementation leave more than one reasonable path. They are not a catalog of component-specific rules. If a rule names a specific interface property, method, protocol action, or source file, it usually belongs in the relevant component doc or a `gotcha:` entry instead.

## Mission

Agent Host exists to make VS Code a first-class host for autonomous coding agents, while using AHP as a general agent/client coordination protocol. The product pressure from the real Copilot path is valuable because it helps discover the right protocol shape, but protocol concepts should be named in agent-domain terms rather than Copilot SDK or VS Code UI terms.

The defining property of AHP is that the agent runs without a client. Clients are viewers/controllers that can connect, disconnect, reconnect, and coexist. That property explains the long-lived host, immutable state, reducers, `serverSeq`, and the need for shared semantics across clients.

## Terminology and comparison points

When Rob says **Agent Host**, he usually means the new AHP-backed implementation in VS Code core: provider/process code under `src/vs/platform/agentHost/`, workbench chat adapters under `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/`, and Sessions app providers under `src/vs/sessions/contrib/agentHost/` and `src/vs/sessions/contrib/remoteAgentHost/`. This is the implementation we are moving toward.

When Rob says **extension-host CLI** or **extension-host Copilot CLI**, he means the older, more fully fleshed out Copilot CLI integration that runs inside the Copilot extension host. It lives in `extensions/copilot/src/extension/chatSessions/copilotcli/`, with registration in `extensions/copilot/src/extension/chatSessions/vscode-node/chatSessions.ts`. Useful comparison anchors:

- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotcliSession.ts` — the extension-host session implementation around the Copilot CLI SDK.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/copilotCli.ts` — model and SDK service wrappers for the extension-host CLI path.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/permissionHelpers.ts` — read/write/shell/MCP permission handling.
- `extensions/copilot/src/extension/chatSessions/copilotcli/common/copilotCLITools.ts` — SDK tool rendering, tool-call interpretation, prompt/reference extraction, and related chat UI data conversion.
- `extensions/copilot/src/extension/chatSessions/copilotcli/node/mcpHandler.ts`, `exitPlanModeHandler.ts`, `logger.ts`, and `copilotCLISkills.ts` — mature extension-host behavior that is often the best parity reference when adding Agent Host SDK features.

When Rob says **VS Code agent**, he usually means the original Copilot chat participant built on the VS Code extension API for chat participants, not AHP. It is registered through `extensions/copilot/src/extension/conversation/vscode-node/chatParticipants.ts`; participant names and IDs live in `extensions/copilot/src/platform/chat/common/chatAgents.ts` (`vscodeAgentName = 'vscode'`, with ID `github.copilot.vscode`). That path routes each request through `ChatParticipantRequestHandler` and the extension chat participant API rather than a long-lived AHP session.

Use the extension-host CLI as a parity and product-behavior reference, especially for SDK-backed features that Agent Host has not yet grown. Do not copy it blindly. The extension-host CLI is constrained by extension API shape, private SDK surfaces, and older session architecture; Agent Host should translate the learned behavior into AHP-native protocol/state/provider concepts.

## Principles

- **Model the agent domain directly.** AHP should describe durable agentic coding concepts: sessions, turns, tools, resources, permissions, files, terminals, checkpoints, authentication, and lifecycle. VS Code UI shapes and Copilot SDK objects are evidence, not boundaries.
- **Let Copilot and the extension-host CLI teach the protocol without leaking them into it.** Build against the real Copilot-backed experience first, and compare against the mature extension-host CLI when useful, but do not bake Copilot-specific or extension-host-specific implementation details into shared protocol names, state, or client expectations.
- **SDK shapes are evidence, not authority.** If an SDK shape maps to a stable agent-domain concept, encode the concept in AHP language. If it is provider plumbing, keep it behind the provider boundary.
- **Correct wrong shapes while AHP is pre-v1.** Breaking protocol changes are acceptable before v1 when they make the model simpler, more semantic, or better placed. Update the in-tree provider/client path coherently; do not add compatibility scaffolding just to preserve a bad shape.
- **Prefer explicit shared semantics over client inference.** If multiple clients or surfaces need to understand the same meaning, make that meaning part of AHP state, actions, commands, or errors. Do not force every client to reverse-engineer behavior from generic events or incidental fields.
- **Keep well-known conventions minimal.** A narrow convention is acceptable when it supports a real UX/product need, is documented in one place, and degrades gracefully for agents that do not participate. Do not treat existing conventions as permission to add more stringly coupling by default.
- **Put truth at the layer that owns it.** Durable session facts that are part of the agent/client contract should live in AHP state. VS Code workbench and Sessions app code should adapt, cache, or view-model that truth unless the state is truly local to one surface.
- **Keep UI adapters honest.** Design AHP independently of VS Code UI. Then map AHP concepts into existing chat/session UX where the mapping is honest; if the protocol concept is real and VS Code lacks the right UI shape, adapt the UI layer rather than distorting the protocol.
- **Fail explicitly for contract violations.** Required AHP contracts should fail with typed errors or visible diagnostics when violated. Silent fallbacks are for intentional optional behavior, not for broken required behavior.
- **Prefer the simplest faithful model.** Future-oriented design is good when it names a stable domain concept. Avoid speculative abstraction, generic escape hatches, or provider matrices that are not yet justified by real workflow pressure.
- **Validate where the contract lives.** Test protocol semantics at the protocol/reducer layer, provider obligations at the provider layer, and adapter behavior at the workbench/session layer. Add higher-level integration coverage when the value comes from multiple layers working together.
- **Record reusable judgment in docs, history in changes.** Component docs and this principles doc preserve current reusable truths and values. `changes/` preserves the narrative of what was tried, why a decision was made, and what was misunderstood. Promote only the distilled reusable lesson into docs.

## Agent behavior

When a decision follows these principles, existing code patterns, and the relevant component docs, make the decision and keep moving. Ask the user when a choice changes the protocol/domain model, promotes a new reusable principle, or trades off two existing principles.

Push back on protocol or API shapes that put a concept at the wrong layer, mirror a provider too closely, or force consumers to work around a bad contract. During pre-v1 iteration, prefer correcting misplaced concepts at their source over adapting every consumer around them.

## Non-goals

- This is not a stable-v1 compatibility policy. AHP is still allowed to break before v1 when the break improves the domain model.
- This is not a catalog of component-specific gotchas. Put those in the relevant component doc's `## Debt & gotchas` section.
- This is not a substitute for reading code and relevant docs. The code remains the source of truth; this doc biases judgment under ambiguity.

## Changelog

- **2026-04-23** — f32a933746 — initial design principles distilled from the knowledge-base design interview; added terminology for Agent Host, extension-host Copilot CLI, and the original VS Code agent