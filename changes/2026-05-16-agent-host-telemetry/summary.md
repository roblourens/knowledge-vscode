# Agent Host telemetry

**Date:** 2026-05-16
**VS Code branch:** agents/vsckb-plan-i-need-to-add-telemetry-which-32f09653
**VS Code SHA at finalize:** 73f8f98fef
**PR:** https://github.com/microsoft/vscode/pull/316797

## What was done

Added VS Code product telemetry plumbing inside the Agent Host process. Both host entry shells now create and register an `ITelemetryService`, `AgentService` threads it into the server-side DI scope, and `AgentSideEffects` can emit product telemetry from inside the host process rather than from a workbench UI adapter.

The first event is `agentHost.userMessageSent`, reported through `AgentHostTelemetryReporter` whenever a user message is actually handed to an agent provider in the direct or queued-message send path. The event deliberately avoids content, paths, project details, model IDs, attachment labels, tool names, and client display names.

The change also added privacy-safe disablement propagation: local host spawns inherit parent `--disable-telemetry`, connected clients send root config `telemetryLevel`, and the process-local telemetry service permanently applies the most restrictive level it has seen.

## Key decisions

- Agent Host owns direct telemetry appenders rather than proxying through a workbench/shared process, because the standalone WebSocket host has no guaranteed VS Code parent process.
- Server-side send telemetry belongs in `AgentSideEffects`, not provider-specific agents and not workbench chat adapters, because it records the point where AHP state becomes `agent.sendMessage(...)`.
- Client telemetry level is propagated via root config state, not a bespoke extension JSON-RPC method, so local and remote clients can share one simple path.
- Root config stores telemetry level as string enum values (`all`, `error`, `crash`, `off`) rather than numeric VS Code enum values.
- If any startup path or connected client disables telemetry, the Agent Host process stays disabled; it does not re-enable even if a later client has telemetry enabled.
- Event definitions and GDPR classifications live in `AgentHostTelemetryReporter` so `AgentSideEffects` stays focused on side-effect routing.

## What went wrong or was misunderstood

- The first disablement design used a custom extension method before the root-config path was chosen. That would have made the behavior less reusable for non-VS Code clients — **prevented by:** the new [agent-host-telemetry](../../docs/agent-host-telemetry.md#disablement-and-telemetry-level-propagation) doc and the [remote protocol client](../../docs/agent-host-remote-protocol-client.md#client-fed-root-config) update.
- Root config initially used raw numeric `TelemetryLevel` values. That was too VS Code-specific and less auditable on the wire — **prevented by:** the new telemetry doc's string-enum rule for `telemetryLevel`.
- The event first included redundant booleans (`isInitialTurn`, `hasActiveClient`, `hasAttachments`). They added schema surface without new information — **prevented by:** the new telemetry doc's rule to avoid derived booleans in `agentHost.userMessageSent`.
- The session ID field was initially named `sessionId`, which hygiene rejects as a reserved common telemetry property. The event now uses `agentSessionId` — **prevented by:** the new telemetry doc's guidance to avoid reserved common telemetry property names.
- Agent Host protocol/runtime IDs were briefly classified as `EndUserPseudonymizedInformation`, but they are not end-user pseudonymized identifiers. They now use `SystemMetaData` — **prevented by:** the new telemetry doc's classification note for `agentSessionId` and `activeClientId`.
- The test for active-client telemetry initially assumed calling `AgentSideEffects.handleAction(SessionActiveClientChanged)` would update state. In production the state manager applies the action before side effects run — **prevented by:** this summary's narrative; no new doc entry because it is a test setup detail rather than a component invariant.
- A merge from `origin/main` conflicted in `remoteAgentHostProtocolClient.ts` because main had recently switched liveness setup to `_resetLivenessTimers()`. The resolution had to preserve the telemetry config listener while adopting the new liveness initialization — **prevented by:** this summary; the remote client doc already covers liveness at the right level and the conflict was ordinary merge timing.

## What we learned

- OSS/dev builds can validate the event path without sending real telemetry: `TelemetryLogAppender` writes `Telemetry (Not Sent)` lines such as `telemetry/agentHost.userMessageSent` to `telemetry.log`.
- `AgentSideEffects.handleAction(...)` does not receive action envelope origin, so any client metadata in send telemetry must be described honestly as current session state, not the dispatching client.
- Root config is a practical path for host-wide client-environment facts when the host process needs a value and the value should be usable by local and remote clients.

## Doc updates

- Created [agent-host-telemetry](../../docs/agent-host-telemetry.md) with process bootstrap, disablement propagation, event placement, event privacy/classification guidance, OSS validation, and gotchas for permanent disablement, root-config dispatch, and active-client semantics.
- Updated [agent-host-topology](../../docs/agent-host-topology.md) to mention product telemetry as a shared host-process service and add telemetry placement to the where-to-put-new-code tree.
- Updated [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md) to document post-handshake root-config telemetry-level dispatch.
- Updated [index](../../vsckb/index.md) with the new telemetry doc and a cross-cutting telemetry-disablement gotcha.
- Removed the session plan folder `vsckb/plan/2026-05-16-agent-host-telemetry/`.
