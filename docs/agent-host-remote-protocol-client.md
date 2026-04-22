# Remote Agent Host Protocol Client

_Covers: src/vs/platform/agentHost/browser/remoteAgentHostProtocolClient.ts, src/vs/platform/agentHost/browser/webSocketClientTransport.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostProtocolClient.test.ts, src/vs/platform/agentHost/test/electron-browser/remoteAgentHostService.test.ts_

`RemoteAgentHostProtocolClient` is the browser-side `IAgentConnection` implementation for one remote Agent Host. It sits below the Agents app's remote Sessions provider and above a concrete transport (`WebSocketClientTransport`, SSH relay, or tunnel relay). Consumers should treat it like any other `IAgentConnection`: initialize, subscribe, dispatch, create/list/dispose sessions, and read state through `AgentSubscriptionManager`.

For the broader local/remote topology, start with [agent-host-topology](./agent-host-topology.md). For the protocol contract and generated command/action types, see [agent-host-protocol](./agent-host-protocol.md).

## Request lifecycle

Outgoing JSON-RPC requests are correlated by numeric id in `_pendingRequests`. The client now makes the lifecycle rule explicit:

- A matching response completes or rejects exactly one pending request, then removes it from the map.
- A transport close rejects every pending request with `RemoteAgentHostProtocolError.connectionClosed(address)`.
- Client disposal rejects every pending request with `RemoteAgentHostProtocolError.disposed(address)`.
- Requests started after close/dispose reject immediately and do not send on the transport.
- Explicit client-transport `connect()` is raced against close/dispose before `initialize`; disposal during a never-resolving transport connect rejects promptly.

`RemoteAgentHostProtocolError` preserves JSON-RPC `code`, `message`, and optional `data`. Prefer checking `code` over matching strings. The local synthetic close/dispose code is currently `-32000` because these failures happen client-side before a server-defined AHP error exists.

## Extension request path

Most requests use the generated protocol `ICommandMap`. VS Code also has a small extension method, `shutdown`, that is not part of the public AHP command map. Keep those methods on a separate typed extension-command map in this client; do not cast request objects as response shapes. If an extension method becomes part of AHP proper, move it to the protocol repo first and regenerate VS Code's `state/protocol/` mirror.

## Disposal ordering

`RemoteAgentHostProtocolClient.dispose()` calls `_handleClose(RemoteAgentHostProtocolError.disposed(...))` before `super.dispose()`. This ordering is load-bearing. `Disposable` field initializers register emitters before constructor-registered disposables, so a `toDisposable(...)` registered in the constructor runs after the `_onDidClose` emitter has already been disposed. `_raceClose()` relies on `onDidClose`, so disposal must mark the client closed and fire the close event before superclass disposal begins.

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

The 2026-04-21 audit intentionally fixed only request lifecycle and structured errors. These adjacent items remain open and are good follow-up tasks:

- Implement real protocol reconnect in the remote client: stable client id across reconnects, remembered subscriptions, `reconnect` command with `lastSeenServerSeq`, replay/snapshot handling, and optimistic action reconciliation.
- Add focused `WebSocketClientTransport` tests for error-then-close exactly-once behavior, malformed/non-object messages, send-after-close behavior, and dispose-triggered close behavior.
- Align WebSocket, SSH relay, and tunnel relay close semantics so remote bugs do not depend on the transport path.
- Revisit whether the local `-32000` close/dispose code should become a named shared client-side constant or a documented AHP-side code.

## Debt & gotchas

- **debt** (2026-04-21, remoteAgentHostProtocolClient.ts:connect) - remote reconnect still behaves like a fresh `initialize`; it does not use AHP replay/snapshot reconnect semantics with stable subscriptions and `lastSeenServerSeq`.
- **debt** (2026-04-21, webSocketClientTransport.ts:onClose) - WebSocket/SSH/tunnel relay close semantics are still not covered by a shared transport test matrix; add once-gated close, malformed-frame, send-after-close, and dispose-trigger tests before refactoring transport behavior.
- **gotcha** (2026-04-21, remoteAgentHostProtocolClient.ts:dispose) - disposal must call `_handleClose(disposed)` before `super.dispose()` so `_onDidClose` is still live for `_raceClose()` listeners, and so intentional client disposal wins over transports that emit `onClose` during disposal.

## Changelog

- **2026-04-21** - `b1564bc1e1` - initial entry after the remote protocol client lifecycle cleanup and Copilot review follow-up.
