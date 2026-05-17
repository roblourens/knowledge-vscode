# Agent Host telemetry

_Covers: src/vs/platform/agentHost/node/agentHostTelemetryService.ts, src/vs/platform/agentHost/node/agentHostTelemetryReporter.ts, src/vs/platform/agentHost/node/agentSideEffects.ts, src/vs/platform/agentHost/node/agentService.ts, src/vs/platform/agentHost/node/agentHostMain.ts, src/vs/platform/agentHost/node/agentHostServerMain.ts, src/vs/platform/agentHost/electron-main/electronAgentHostStarter.ts, src/vs/platform/agentHost/node/nodeAgentHostStarter.ts, src/vs/platform/agentHost/electron-browser/localAgentHostService.ts, src/vs/platform/agentHost/browser/remoteAgentHostProtocolClient.ts, src/vs/platform/agentHost/common/agentHostSchema.ts, src/vs/platform/agentHost/test/node/agentHostTelemetryService.test.ts, src/vs/platform/agentHost/test/node/agentSideEffects.test.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostProtocolClient.test.ts_

Agent Host owns a VS Code `ITelemetryService` inside the host process so server-side facts can be logged where they happen. This is product telemetry, not the OTel span pipeline used for SDK request tracing. Use `AgentHostOTelService` for trace/span instrumentation and this telemetry path only for GDPR-classified VS Code product events.

## Process bootstrap

Both host entry shells create telemetry through `createAgentHostTelemetryService`:

- `agentHostMain.ts` for the local utility/child-process MessagePort host.
- `agentHostServerMain.ts` for the standalone WebSocket host.

The helper mirrors other non-renderer VS Code processes: it builds appenders in-process, using `TelemetryLogAppender` for OSS/dev logging-only output and `OneDataSystemAppender` when product telemetry is supported. It returns `NullTelemetryService` when telemetry is explicitly disabled, unsupported, or when the standalone server is running in quiet/mock-only mode without a logger.

`AgentService` receives the service and registers it in its internal strict `ServiceCollection`, so shared server-side helpers such as `AgentSideEffects` and provider-side code can inject `ITelemetryService` without reaching back to the process entry point.

## Disablement and telemetry level propagation

Agent Host must treat telemetry disablement as a one-way process-local kill switch:

1. Parent process disablement is forwarded into local host spawns as `--disable-telemetry`.
2. Each client sends its current telemetry level through root config state after connect/handshake and when the setting changes.
3. `AgentHostTelemetryService` applies the most restrictive level it has seen. Once the effective level reaches `TelemetryLevel.NONE`, it never re-enables for that process.

The root config key is `telemetryLevel` (`AgentHostTelemetryLevelConfigKey`). Its value is a string enum matching VS Code's `telemetry.telemetryLevel` setting: `'all' | 'error' | 'crash' | 'off'`. Do not put raw numeric `TelemetryLevel` values into AHP state; root config is cross-client state and should use auditable values that other clients can produce without importing VS Code enums.

Client telemetry propagation is intentionally fire-and-forget. Local and remote clients dispatch `root/configChanged` through the non-optimistic connection path with `clientSeq: 0`; this is host configuration input, not user-authored session history.

## Event placement

Emit server-side Agent Host telemetry from the server-side point that owns the fact. For user-message telemetry, that is `AgentSideEffects`, because it is where a `session/turnStarted` action becomes an `agent.sendMessage(...)` call.

There are two send paths:

- direct turns handled by `AgentSideEffects.handleAction(SessionTurnStarted)`;
- queued messages consumed by `_tryConsumeNextQueuedMessage`.

Both paths must report at the same boundary: immediately before or while handing the message to the agent provider. Do not add a workbench-side duplicate for the same event; that would answer a different question ("UI requested a send") and would miss queued/server-side sends.

Keep `AgentSideEffects` thin. Event typings, GDPR classifications, and the `publicLog2` call live in `AgentHostTelemetryReporter`.

## `agentHost.userMessageSent`

`AgentHostTelemetryReporter.userMessageSent(...)` logs `agentHost.userMessageSent` when a user message is handed to an agent provider.

Allowed fields are coarse, non-content metadata already available at send time:

- `provider`
- `agentSessionId`
- `source` (`direct` or `queued`)
- `isSubagentSession`
- `turnCount`
- optional `activeClientId`
- optional `activeClientToolCount`
- optional `activeClientCustomizationCount`
- `attachmentCount`

Do not include prompt text, session URI, working directory, project URI/name, file paths, attachment labels, model IDs, tool names, or client display names. Avoid redundant booleans that can be derived from existing values, such as `turnCount === 0`, presence of `activeClientId`, or `attachmentCount > 0`.

The IDs in this event are Agent Host protocol/runtime identifiers, not end-user pseudonymized identifiers. Classify them as `SystemMetaData` unless a future event truly carries a user pseudonymous identity. Also avoid reserved common telemetry property names such as `sessionId`; hygiene rejects them, and event-specific names such as `agentSessionId` are clearer.

`activeClientId` is the current active client on `SessionState.activeClient`, not necessarily the client that originally dispatched the action. `AgentSideEffects.handleAction(...)` is intentionally not passed the action envelope origin.

## OSS/dev validation

OSS/dev builds without real product telemetry still exercise the send path through logging-only telemetry. When the host is not started with `--disable-telemetry`, `TelemetryLogAppender` writes entries such as `telemetry/agentHost.userMessageSent` to `telemetry.log` as "Telemetry (Not Sent)". This is useful for manually proving the event was attempted without sending real telemetry.

## Debt & gotchas

- **gotcha** (2026-05-16, agentHostTelemetryService.ts:updateTelemetryLevel) — once any startup path or connected client disables telemetry, the Agent Host process must not re-enable it later. The service intentionally applies the most restrictive level and treats `TelemetryLevel.NONE` as permanent for that process.
- **gotcha** (2026-05-16, localAgentHostService.ts / remoteAgentHostProtocolClient.ts:telemetry root config dispatch) — client telemetry level is propagated as root config state using the string enum `telemetryLevel` value, not a VS Code extension JSON-RPC method and not a numeric `TelemetryLevel`. Dispatch it fire-and-forget via the non-optimistic action path with `clientSeq: 0`.
- **gotcha** (2026-05-16, agentHostTelemetryReporter.ts:activeClientId) — `activeClientId` means the session's current active client at send time, not the dispatching client origin. Do not reinterpret it as "client that sent this message" unless the side-effects layer starts receiving action envelope origin explicitly.

## Changelog

- **2026-05-16** — 73f8f98fef — initial entry after Agent Host product telemetry wiring and `agentHost.userMessageSent` landed in PR #316797.
