# chat: register in-place action for programmatic chat session contributions

**Date:** 2026-04-26
**VS Code branch:** roblou/agents/vs-code-copilot-cli-agent-issue
**VS Code SHA at finalize:** 8b0b362bd2
**PR:** [#312628](https://github.com/microsoft/vscode/pull/312628)

## What was done

Switching to the local Copilot CLI agent host from the session-type picker in VS Code threw `command 'workbench.action.chat.openNewChatSessionInPlace.agent-host-copilotcli' not found`. Two fixes:

1. In `ChatSessionsService.registerChatSessionContribution` (`src/vs/workbench/contrib/chat/browser/chatSessions/chatSessions.contribution.ts`), also populate `_contributionDisposables` and call `_updateHasCanDelegateProvidersContextKey()` on both register and dispose. Programmatic registrations (used by both `AgentHostContribution` and `RemoteAgentHostContribution`) bypass `_evaluateAvailability`, which is the only path that drives those listeners for extension contributions.
2. In `AgentHostContribution._registerAgent` (`src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts`), suffix `agent.displayName` with `" - Agent Host"` in VS Code to disambiguate from the extension-host Copilot CLI harness which uses the same `"Copilot CLI"` label. The Agents window keeps the original displayName.

## Key decisions

- Fixed the bug in the generic chat-sessions layer rather than per-agent-host. `registerChatSessionContribution` is a public API on `IChatSessionsService`; programmatic contributions should behave the same as extension contributions for the autorun and the context-key update. Per-agent fixes would have duplicated the wiring across `AgentHostContribution` and `RemoteAgentHostContribution` (and any future programmatic registrant).
- Kept the displayName disambiguation localized to `AgentHostContribution` (gated on `_isSessionsWindow`) rather than mutating `agent.displayName` upstream — only this surface has the collision in VS Code.

## What went wrong or was misunderstood

- **Initial fix only addressed one of two listeners gated on `_contributionDisposables.has(type)`.** I fixed the autorun that registers `openNewChatSessionInPlace.<type>` but missed that the same `_contributionDisposables` membership also drives `_updateHasCanDelegateProvidersContextKey()` (called only inside `_evaluateAvailability`). The Copilot reviewer caught it. Lesson: when a fix involves "make programmatic registrations look enabled," scan all readers of the enabled-set, not just the one whose symptom you're chasing. — **prevented by:** new `gotcha:` on `agent-host-session-handler.md` enumerating both listeners and the requirement to audit any third one.
- **Confused naming around the agent host's session type.** `electron-browser/chat.contribution.ts:259` had a hardcoded command for `agent-host-copilot` (matching the stale `SessionType.AgentHostCopilot = 'agent-host-copilot'` enum) while the actual runtime type is `agent-host-${agent.provider}` = `agent-host-copilotcli`. The hardcoded fallback was always dead code and masked nothing — but it took a minute to confirm it wasn't relevant. Not worth its own gotcha; flagged here for the next person who touches it. — **prevented by:** this summary entry.
- **Almost shipped a per-provider hardcoded label.** First pass at the displayName disambiguation hardcoded `"copilot-cli-agenthost"` for `agent.provider === 'copilotcli'`. The user pushed back with "just suffix `- Agent Host`" — generic, works for any future agent-host provider. Lesson: when a UI label depends on a runtime-discovered provider, prefer a generic transform over per-provider switches. — **prevented by:** new `gotcha:` on `agent-host-session-handler.md` documenting the suffix pattern.

## What we learned

- `IChatSessionsService.registerChatSessionContribution` is callable both from the extension point and programmatically, but the two paths run through different availability machinery. Anything that should fire for "any registered contribution" needs to be wired in both `_evaluateAvailability` AND `registerChatSessionContribution`.
- The session-type picker's "New {0} Session" label comes from `IChatSessionsExtensionPoint.displayName`. For dynamically-registered providers, that's whatever the agent host advertised (`agent.displayName`). When two registrants pick the same human-readable name, the UI can't distinguish them.

## Doc updates

- `docs/agent-host-session-handler.md` — added two gotchas (registration wiring + displayName suffix); changelog entry `2026-04-26` / `8b0b362bd2`.
