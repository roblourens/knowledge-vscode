# SSH X-button: restore entry removal on disconnect

**Date:** 2026-05-25
**VS Code branch:** agents/vsckb-implement-the-x-button-on-the-remote-385e7265
**VS Code SHA at finalize:** 69e5d4640d
**PR:** [#318262](https://github.com/microsoft/vscode/pull/318262)

## What was done

Restored the X-button behavior on SSH-backed remote agent host entries in the workspace picker. Clicking X now actually disconnects the SSH tunnel and removes the entry from `RemoteAgentHostsSettingId` storage, so it does not auto-reconnect mid-disconnect and does not come back on the next window reload.

The fix is a small refactor of `RemoteAgentHostContribution._disconnectSSHOnDemand` in `src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteAgentHost.contribution.ts`: call `IRemoteAgentHostService.removeRemoteAgentHost(connection.address)` BEFORE `ISSHRemoteAgentHostService.disconnect(connectionKey)`. The ordering is load-bearing — see the new gotcha on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md#debt--gotchas).

The disconnect ordering was extracted into an exported helper `disconnectSSHEntry(connection, remoteAgentHostService, sshService)` plus an exported `sshConnectionKey(connection)` helper, both covered by new tests in `remoteAgentHost.contribution.test.ts`. The helpers and tests are the regression guard — the next time someone re-wires this path, the ordering test will fail loudly.

## Key decisions

- **No SSH suppression marker.** Unlike tunnels (where the cached tunnel is valuable and disconnect intent has to persist as a suppression flag, see [`2026-05-01-inline-tunnel-disconnect-button`](../2026-05-01-inline-tunnel-disconnect-button/summary.md)), SSH `IRemoteAgentHostSSHConnection` entries are essentially `{name, sshConfigHost}` pointing at `~/.ssh/config`. Removal is the correct disconnect-intent semantic; the user can re-add by re-picking the alias.
- **Keep the explicit `_sshService.disconnect(connectionKey)`.** `removeRemoteAgentHost` already runs the entry's `transportDisposable`, which calls `_mainService.disconnect(connectionId)` for SSH and tears down the main-process tunnel (per the 2026-04-22 fix). The explicit `_sshService.disconnect` afterwards is belt-and-suspenders to clear the connection by its connection-key as well — it costs nothing and preserves the historical teardown shape.
- **Refactor for testability, not capability.** The fix itself is one line; extracting `disconnectSSHEntry`/`sshConnectionKey` lets us test the ordering without standing up `RemoteAgentHostContribution`'s ~20 service dependencies. It also leaves the helpers exported for future call sites that need the same teardown.
- **No `_instantiateProvider` seam yet.** Considered subclassing `RemoteAgentHostContribution` with a stub-provider seam mirroring `TestTunnelContribution`, but it was overkill for verifying the ordering. Document-and-test what the helper guarantees; revisit if other contribution-level paths need integration coverage.

## What went wrong or was misunderstood

- **Overbuilt the first attempt to ~140 lines.** Started by mirroring the tunnel suppression pattern (persisted disconnect-intent on `ISSHRemoteAgentHostService`). User pushed back. SSH entries are not tunnels — the cached entry has no value, removal is the right shape. — **prevented by:** new "SSH-backed remote providers: disconnect intent is removal" section + `gotcha:` on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md#ssh-backed-remote-providers-disconnect-intent-is-removal); plus this summary's "Key decisions" pointing future SSH disconnect changes at the simpler model.
- **Didn't immediately suspect a regression.** The first investigation jumped straight to "we need a suppression mechanism." Only after the user asked "when did this regress?" did I git-blame and find PR #316810 (May 16, 2026), which wired SSH into the tunnel-style `_disconnectOnDemand` hook without preserving the entry-removal call established by the [2026-04-22 SSH fix](../2026-04-22-ssh-remove-remote-tears-down/summary.md). Asking "when did this last work?" before "how do we build the fix?" would have surfaced the much smaller fix shape immediately. — **prevented by:** this summary explicitly records the regression history; future SSH disconnect changes should land alongside a test in `remoteAgentHost.contribution.test.ts` so the next rewire fails loudly.
- **The synchronous-event hazard was not obvious from reading the code.** `_sshService.disconnect()` looks like an async tunnel teardown, but it fires `onDidCloseConnection` → `notifyConnectionClosed` → `onDidChangeConnections` *synchronously* during the await. That event drives `_reconcile` → `_reconnectSSHEntries`, which re-adds the entry mid-disconnect if storage still has it. The first cut of the fix put `removeRemoteAgentHost` AFTER `_sshService.disconnect` and it didn't work for that reason. — **prevented by:** the new `gotcha:` on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md#debt--gotchas) calls out the synchronous event chain by name and pins the ordering. The `disconnectSSHEntry` test uses a blocked `DeferredPromise` to make the ordering observable.
- **Same area, second regression in five weeks.** PR [#311992](https://github.com/microsoft/vscode/pull/311992) (2026-04-22) made the SSH X-button work in the first place by ensuring the per-entry `transportDisposable` ran. There was no contribution-level test of the resulting disconnect chain, so PR #316810 broke the same user-visible behavior six weeks later without anyone noticing until the user filed it. — **prevented by:** the new `disconnectSSHEntry`/`sshConnectionKey` regression tests, plus the existing per-entry-store gotchas on [agent-host-topology](../../docs/agent-host-topology.md#debt--gotchas) now have a sibling gotcha on the contribution-level ordering.
- **Local `scripts/test.sh` was broken (stale Electron binary from Jan 1980 timestamp); `npm run test-node` couldn't load the test either due to a `.css` ESM resolver error.** Fell back to verifying the helper logic via an inline `node` script and let CI run the actual mocha tests. CI passed. — **prevented by:** this is already documented in [testing](../../docs/testing.md); the lesson reinforced is to validate the helper's behavior with a tiny standalone script when the unit-test runner is wedged, instead of waiting on CI for every iteration.

## What we learned

- The `_disconnectOnDemand` hook (introduced by the tunnel inline-X PR) is a useful provider seam, but its name doesn't tell the implementer that the underlying transport's disconnect call fires `onDidChangeConnections` synchronously. Any future transport added behind `_disconnectOnDemand` has the same ordering hazard — record the entry-removal-before-teardown rule explicitly per transport.
- The cycle of two regressions in this area suggests the SSH disconnect chain (X → workspace picker → `removeRemoteHost` → `provider.disconnect()` → `_disconnectSSHOnDemand` → `removeRemoteAgentHost` + `_sshService.disconnect` → per-entry `transportDisposable` → `_mainService.disconnect`) is long enough that ad-hoc reasoning isn't enough; we need cheap regression tests at the contribution boundary, not just at the SSH service boundary (where the 2026-04-22 tests live).

## Doc updates

- Updated `docs/agent-host-sessions-providers.md`:
  - Added a new "SSH-backed remote providers: disconnect intent is removal" section explaining the tunnel-vs-SSH semantic difference, the synchronous-event ordering hazard, and the contract that `removeRemoteAgentHost` runs before `_sshService.disconnect`.
  - Added a `gotcha:` (`2026-05-25, remoteAgentHost.contribution.ts:_disconnectSSHOnDemand + disconnectSSHEntry`) for the ordering rule.
  - Added a 2026-05-25 changelog entry.
- Updated `docs/remote-agent-host-management-ux.md`:
  - Extended the existing workspace-picker inline-X `gotcha:` to call out the SSH path alongside tunnel.
  - Added a 2026-05-25 changelog entry.
- Updated `index.md`:
  - Replaced the cross-cutting "tunnel disconnect suppression" gotcha with a broader "remote disconnect intent — tunnel vs SSH" gotcha that covers both transports and points at both per-component sections.
