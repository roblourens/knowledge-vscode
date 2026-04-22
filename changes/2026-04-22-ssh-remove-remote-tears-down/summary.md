# SSH Remove Remote tears down the tunnel

PR: [microsoft/vscode#311992](https://github.com/microsoft/vscode/pull/311992) · branch `roblou/agents/ssh-remote-disconnect-issue` · HEAD `e559871236`

## What changed

- Renamed `IRemoteAgentHostService.addSSHConnection` → `addManagedConnection` and added an optional `transportDisposable?: IDisposable` parameter. The renderer service registers it on the per-entry `DisposableStore` so it runs when the entry is removed (user click), reconciled away, or the service is disposed.
- `SSHRemoteAgentHostService` now passes a `transportDisposable` that synchronously drops the handle from `_connections`, fires the change event, marks the protocol-client handle closed, disposes the handle, then best-effort calls `_mainService.disconnect(connectionId)`. Synchronous `_connections` removal makes the `if (existing) return existing` early-return in `connect()` / `reconnect()` safe for an immediate reconnect.
- Both `connect()` and `reconnect()` now route through a shared `_setupConnection(result)` helper that wraps handshake → handle creation → registration in one try/catch. On any failure: drop the handle, fire change, dispose protocol client + handle, best-effort `_mainService.disconnect()`. (Previously `reconnect()` had no error handling at all.)
- New tests:
  - `src/vs/platform/agentHost/test/electron-browser/sshRemoteAgentHostService.test.ts` — 4 renderer-side tests covering connect → remove → reconnect with a mock SSH main service and a mock `IRemoteAgentHostService` that mirrors the real per-entry-store cleanup.
  - 3 platform tests added under the existing `remoteAgentHostService.test.ts` for `addManagedConnection` covering the transport-disposable contract.
- Tunnel renderers needed only the rename — `TunnelRelayTransport.dispose()` already disconnects.

## What went wrong

- **The bug was three layers deep, not one.** `SSHRelayTransport.dispose()` only removed IPC listeners (didn't tell main to close the SSH tunnel), the renderer `_connections` map only got cleared via `onDidCloseConnection` from main (which never fired), and the `if (existing) return existing` short-circuit in `connect()` then handed the stale handle back on the next user attempt. Fixing only the dispose method would have left the second and third layers leaking. The fix had to register an entry-lifetime cleanup that did all three jobs in the right order. The new `RemoteAgentHostService.IConnectionEntry.store` gotcha and the `*RelayTransport.dispose` gotcha in [agent-host-topology](../../docs/agent-host-topology.md) capture this so the next person isn't surprised.
- **`addSSHConnection` wasn't SSH-specific.** The same method was used by both SSH and tunnel renderers, but the name implied otherwise. Renamed to `addManagedConnection`. The naming had nothing to do with SSH; it described the renderer-managed-handle case (vs handles created by the main side). Caught while reading callers — would have been an easy thing to miss in review.
- **Tunnel changes I almost shipped were redundant.** I initially added a `toDisposable(...)` wrapper inside `tunnelAgentHostServiceImpl.ts` that called `_mainService.disconnect()` on teardown. The user pushed back: `TunnelRelayTransport.dispose()` already does exactly that. Dropped the wrapper, kept only the rename. The discipline lesson: when a fix shape "happens to work" identically across multiple transports, ask whether the transport already does it before piling on a redundant cleanup.
- **`reconnect()` had no error handling.** Copilot review caught this. The original `connect()` had a `try/catch` around the handshake but `addManagedConnection` was outside it; `reconnect()` had nothing. Refactor consolidated both paths through `_setupConnection`, with the try/catch covering handshake + handle creation + registration.
- **Test runner blocked by stale env var.** `./scripts/test.sh` failed with `app.setPath undefined` because the parent shell had `ELECTRON_RUN_AS_NODE=1` set from earlier work. `unset ELECTRON_RUN_AS_NODE` fixed it. Already documented in [testing.md § Workflow tips](../../docs/testing.md), but I forgot — re-reading testing.md should be a reflex when the runner produces a weird native-binary error.
- **Disposable-leak detector bit the test mocks.** `MockProtocolClient` had to take ownership of the transport disposable passed into its constructor (mirroring the real `RemoteAgentHostProtocolClient`), and `MockRemoteAgentHostService` had to extend `Disposable` and clean up still-registered entries on its own `dispose()` (mirroring the real per-entry store cleanup). Tests are a useful forcing function for getting the ownership story right.
- **Deferred:** there's a remove → immediate-reconnect race where main could return the same `connectionId` for an in-flight-being-disposed connection. Documented but not fixed in this PR.

## Knowledge updates

- [agent-host-topology](../../docs/agent-host-topology.md) — added two gotchas (per-entry `DisposableStore` ownership boundary; relay-transport `dispose()` contract) plus a changelog entry.
