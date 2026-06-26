# Remote Agent Host Protocol Client

_Covers: src/vs/platform/agentHost/browser/remoteAgentHostProtocolClient.ts, src/vs/platform/agentHost/browser/webSocketClientTransport.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostProtocolClient.test.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostService.test.ts_

`RemoteAgentHostProtocolClient` is the browser-side `IAgentConnection` implementation for one remote Agent Host. It sits below the Agents app's remote Sessions provider and above a concrete transport (`WebSocketClientTransport`, SSH relay, or tunnel relay). Consumers should treat it like any other `IAgentConnection`: initialize, subscribe, dispatch, create/list/dispose sessions, and read state through `AgentSubscriptionManager`.

For the broader local/remote topology, start with [agent-host-topology](./agent-host-topology.md). For the protocol contract and generated command/action types, see [agent-host-protocol](./agent-host-protocol.md).

## Handshake and version mismatch

`connect()` sends `initialize` with `protocolVersions: [PROTOCOL_VERSION]`, where `PROTOCOL_VERSION` comes from the generated `state/protocol/version/registry.ts`. The server selects a version and returns it in `InitializeResult.protocolVersion`; the current VS Code client offers one generated version, but the wire shape is already an ordered SemVer list.

If the host rejects the handshake with `UnsupportedProtocolVersion` (-32005), the error remains a structured `ProtocolError` with typed `UnsupportedProtocolVersionErrorData.supportedVersions`. The higher-level remote host services convert that through `RemoteAgentHostConnectionStatus.fromConnectError(...)` into an `incompatible` status. That status is intentionally sticky: WebSocket, SSH, and tunnel paths suppress automatic reconnect for protocol mismatches, but manual Reconnect clears the state and tries again.

After a successful handshake the client keeps a stable `clientId`, remembers its last server sequence, and can soft-reconnect when its transport is factory-backed. Reconnect sends AHP `reconnect`, applies either replayed envelopes or server snapshots back through `AgentSubscriptionManager`, and drains wire messages that were queued while the transport was recovering. Passive SSH/tunnel transports without a replacement factory still surface close to the owning service, which decides whether to create a fresh client.

## Request lifecycle

Outgoing JSON-RPC requests are correlated by numeric id in `_pendingRequests`. The client now makes the lifecycle rule explicit:

- A matching response completes or rejects exactly one pending request, then removes it from the map.
- A transport close rejects every pending request with a `ProtocolError` from `connectionClosedError(address)`.
- Client disposal rejects every pending request with a `ProtocolError` from `connectionDisposedError(address)`.
- Requests started after close/dispose reject immediately and do not send on the transport.
- Explicit client-transport `connect()` is raced against close/dispose before `initialize`; disposal during a never-resolving transport connect rejects promptly.
- Requests issued while a soft reconnect is active wait behind the reconnect gate instead of sending on a dead transport. If a reconnect attempt fails, that gate rolls forward to the next attempt so newer requests do not slip through onto the old transport.

`ProtocolError` preserves JSON-RPC `code`, `message`, and optional `data`. Prefer checking `code` over matching strings. The local synthetic close/dispose code is currently `-32000` because these failures happen client-side before a server-defined AHP error exists.

## Reverse filesystem permissions

Remote hosts can ask the client to read/write/list/delete/move resources through reverse JSON-RPC. Those requests are gated by `IAgentHostPermissionService` before they touch `IFileService`:

- Read/list requests need a read grant; write/delete need a write grant; move needs read on the source and write on the destination.
- URIs are canonicalized through `IFileService.realpath` before comparison so `..` and symlink escapes do not bypass an existing grant.
- Denials return `PermissionDenied` (-32009) with `PermissionDeniedErrorData.request`; the host can then issue reverse `resourceRequest` and retry if the user grants access.
- Outgoing `activeClient.customizations` refs get implicit read grants so synced customization/plugin files remain friction-free.

The prompt UI lives outside this client in `AgentHostPermissionUiContribution`; the client only asks the permission service and reports typed protocol errors.

## Active liveness and transport logs

The watchdog now supervises idle links too. Every tick with no pending RPCs sends an application-level `ping`; if a request (including a ping) remains unanswered while no message has arrived for the watchdog window, the client treats the transport as dead and triggers the same reconnect/close path as an explicit socket loss. Servers that do not implement `ping` still produce an error response, which is enough to refresh read activity and prove the path is alive.

Transport JSONL logging is wired around this client by the remote service when Agent Host AHP logging is enabled. Keep that logging at the transport/client boundary: it is for reconstructing request/response/reconnect chronology, not for feature-level business logging.

## Client-fed root config

After a successful handshake, the remote client may send client-environment facts that the host process needs as root config state. Telemetry level is the first such key: the client dispatches `root/configChanged` with the schema-known string enum `telemetryLevel` value so a remote Agent Host can clamp product telemetry off when any connected VS Code client has disabled telemetry. This is fire-and-forget host input, not optimistic user session history; use the non-optimistic dispatch path with `clientSeq: 0`.

For the privacy and disablement rules, see [agent-host-telemetry](./agent-host-telemetry.md#disablement-and-telemetry-level-propagation).

## Session creation URI ownership

`createSession(config?)` must preserve a client-provided `config.session`. The VS Code side now chooses the AHP session URI before asking a remote Agent Host to create the session: the chat/session resource already contains the raw id, and `AgentHostSessionHandler` passes `session: AgentSession.uri(provider, rawId)` through `IAgentConnection.createSession(...)`. The remote protocol client should generate `AgentSession.uri(provider, generateUuid())` only when `config.session` is absent.

This keeps local and remote creation consistent: the client determines the chat session URI over AHP, and the server/remote path honors it. If the remote client ignores `config.session` and generates a different URI, the handler's mismatch check will fail; that is a contract violation, not an id-remapping case.

## Extension request path

Most requests use the generated protocol `ICommandMap`. VS Code also has a small extension method, `shutdown`, that is not part of the public AHP command map. Keep those methods on a separate typed extension-command map in this client; do not cast request objects as response shapes. If an extension method becomes part of AHP proper, move it to the protocol repo first and regenerate VS Code's `state/protocol/` mirror.

## Disposal ordering

`RemoteAgentHostProtocolClient.dispose()` calls `_handleClose(connectionDisposedError(...))` before `super.dispose()`. This ordering is load-bearing. `Disposable` field initializers register emitters before constructor-registered disposables, so a `toDisposable(...)` registered in the constructor runs after the `_onDidClose` emitter has already been disposed. `_raceClose()` relies on `onDidClose`, so disposal must mark the client closed and fire the close event before superclass disposal begins.

Some transports also emit `onClose` from their own `dispose()` path. Intentional client disposal should still surface as `Connection disposed`, not `Connection closed`, so the client-level close marker must win before the transport is disposed.

## Tests

Use focused browser-unit tests for request lifecycle before reaching for remote integration tests. The in-memory fake transport in `remoteAgentHostProtocolClient.test.ts` covers:

- success response completion;
- structured JSON-RPC errors;
- unknown response ids;
- pending request rejection on close and dispose;
- dispose winning when the transport emits close during dispose;
- late responses after close;
- requests started after close/dispose;
- connect races before transport connect resolves;
- request shape and structured error handling for `shutdown`.

Guard broader service interactions with `remoteAgentHostService.test.ts`. Transport-specific close semantics still need their own tests; do not rely on the protocol client suite to prove WebSocket, SSH relay, and tunnel relay behavior is identical.

## Remaining debt candidates

The 2026-04-21 audit intentionally fixed only request lifecycle and structured errors. Soft reconnect landed later; these adjacent items remain open and are good follow-up tasks:

- Add focused `WebSocketClientTransport` tests for error-then-close exactly-once behavior, malformed/non-object messages, send-after-close behavior, and dispose-triggered close behavior.
- Align WebSocket, SSH relay, and tunnel relay close semantics so remote bugs do not depend on the transport path.
- Revisit whether the local `-32000` close/dispose code should become a named shared client-side constant or a documented AHP-side code.

## Debt & gotchas

- **gotcha** (2026-04-30, remoteAgentHostProtocolClient.ts:createSession) - preserve `config.session` when present. The client owns the AHP URI for non-fork session creation; generate a URI only as a fallback for callers that did not request one.
- **debt** (2026-04-21, remoteAgentHostProtocolClient.ts:connect) - remote reconnect still behaves like a fresh `initialize`; it does not use AHP replay/snapshot reconnect semantics with stable subscriptions and `lastSeenServerSeq`.
- **debt** (2026-04-21, webSocketClientTransport.ts:onClose) - WebSocket/SSH/tunnel relay close semantics are still not covered by a shared transport test matrix; add once-gated close, malformed-frame, send-after-close, and dispose-trigger tests before refactoring transport behavior.
- **gotcha** (2026-04-21, remoteAgentHostProtocolClient.ts:dispose) - disposal must call `_handleClose(disposed)` before `super.dispose()` so `_onDidClose` is still live for `_raceClose()` listeners, and so intentional client disposal wins over transports that emit `onClose` during disposal.

## Changelog

- **2026-06-25** — 09c18fe5c5 — reconciliation: the remote client's reverse-RPC, permission-gating, and root-config dispatch architecture still holds. It now also rides the channel-based wire model and multi-chat sessions (chat content arrives on the chat channel) and multiple active clients per session — see [agent-host-protocol](./agent-host-protocol.md). No change to the post-handshake telemetry-level dispatch behavior documented below.

- **2026-05-16** — 73f8f98fef — documented the remote client's post-handshake root-config telemetry-level dispatch and why it uses the non-optimistic action path.

- **2026-05-15** — 12443ea83d — reconciliation: documented soft reconnect/replay gating from `ca28b2066f2`, the reconnect-hang fix in `f91a396d242`, active AHP ping liveness from `90db24b194c`, and transport JSONL logging from `e85a8295788`; the older reconnect debt entry remains below as a cleanup candidate for explicit confirmation.

- **2026-05-04** — 939d3f227c — reconciliation: documented SemVer handshake/incompatible remote status from `e1a89568eb2` and reverse filesystem permission gating / `resourceRequest` negotiation from `c30ed7c4a51`.

- **2026-05-01** — b2e6267136 — reconciliation: no body changes. `8dbb8606e2c2` tightened client-requested session URI preservation, which this doc already covered in the session-creation URI ownership section.
- **2026-04-30** - `928bc0340d` - documented that remote `createSession(config.session)` must honor the client-chosen AHP URI and only generate a new URI when no session was requested.
- **2026-04-24** — `5407371c47` — reconciliation: no doc changes. Type-prefix renames from `0b4570038fe` (`Adopt renamed agent host protocol types`) only affect import names, not the architectural prose. `dcc7279e0d7` (web connection stability + terminal reconnection), `1f9cd94d0da` (SSH tunnel teardown), `037d32ab6b9` (protocol cleanups), and `2289e091159` (host-level settings) live below the architectural concepts this doc describes; the open reconnect/replay and transport close-semantics debt is unchanged.
- **2026-04-21** - `b1564bc1e1` - initial entry after the remote protocol client lifecycle cleanup and Copilot review follow-up.
