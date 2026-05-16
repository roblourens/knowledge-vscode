# Remote Agent Host Management UX

_Covers: src/vs/sessions/contrib/chat/browser/sessionWorkspacePicker.ts, src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteAgentHostActions.ts, src/vs/sessions/contrib/providers/remoteAgentHost/browser/manageRemoteAgentHosts.ts, src/vs/sessions/contrib/providers/remoteAgentHost/browser/remoteHostOptions.ts, src/vs/platform/actionWidget/browser/actionList.ts, src/vs/platform/agentHost/common/sshRemoteAgentHost.ts, src/vs/platform/agentHost/node/sshRemoteAgentHostService.ts_

The remote agent host management UX lives in `src/vs/sessions/contrib/providers/remoteAgentHost/browser/` and provides three surfaces: an SSH connection picker, a tunnel connection picker, a per-remote options popup, and a standalone "Manage Remote Agent Hosts" F1 command. All surfaces use QuickPick from `IQuickInputService`.

For how SSH and tunnel connections are established and maintained at the provider level, see [agent-host-sessions-providers](./agent-host-sessions-providers.md). This doc covers only the picker/action UX layer.

## SSH connection picker (`promptToConnectViaSSH`)

The SSH picker (`promptToConnectViaSSH` in `remoteAgentHostActions.ts`) mirrors the Remote SSH extension's UX:

- **Alias items** — loaded from `ISSHRemoteAgentHostService.listSSHConfigHosts()`, shown as static options.
- **Dynamic "new host" item** — synthesized on every keystroke from whatever the user types, but only when the input matches `user@host` or `user@host:port`. It sorts to the bottom and disappears when input is empty. There is **no static "Enter manually" entry** — the dynamic item is the only affordance for free-form input.
- **Footer items** — `$(plus) Add New SSH Host...` and `Configure SSH Hosts...`, pinned below a separator so they never mix with real host items.

All items are set in a single `quickPick.items` array with separator items for visual grouping. The footer items are always present — they don't change with filter text. The new-host item is filtered in/out by recomputing items on `onDidChangeValue`.

The picker returns `'back'` if the back button was clicked (and `options.showBackButton` was passed); callers that want back navigation should check for this return value and re-invoke their own picker.

## Configure SSH Hosts picker

Invoked from the SSH picker's footer or from the F1 command `workbench.action.sessions.configureSSHHosts`. Lists all SSH config files returned by `ISSHRemoteAgentHostService.listSSHConfigFiles()` and opens the selected file in an editor.

- If only one file exists, it opens directly (no picker shown) — unless `onBack` was passed, in which case the picker is always shown to offer navigation.
- `run(accessor, onBack?)` — the `onBack` parameter is a callback invoked when the back button is clicked. Callers (SSH picker, manage picker) pass a lambda that re-shows their own picker.

## Tunnel connection picker (`promptToConnectViaTunnel`)

Shows dev tunnels from `ITunnelAgentHostService.listTunnels()`. The picker opens immediately in busy state while tunnels are being fetched. Supports `options.showBackButton` and returns `'back'`.

The current remote-tab flow deliberately separates discovery from connection. The Remote experiment can be hidden or gated in the workspace picker, but explicit tunnel/SSH management actions still route through these picker helpers; on tunnel auth paths, keyboard-accessible fallbacks keep the user from being stranded on providers that cannot complete the preferred Microsoft-auth flow end to end.

## Per-remote options (`showRemoteHostOptions`)

`showRemoteHostOptions` in `remoteHostOptions.ts` shows a QuickPick with per-remote actions for a connected `IAgentHostSessionsProvider`:

- **Reconnect** — calls the shared `reconnectRemoteHost(...)` helper. That prefers `provider.connect()` when the provider owns its transport (tunnels), and falls back to `remoteAgentHostService.reconnect(address)` for generic remote providers.
- **Remove** — calls the shared `removeRemoteHost(...)` helper. That prefers `provider.disconnect()` when the provider owns its transport (tunnels), and falls back to `remoteAgentHostService.removeRemoteAgentHost(address)` for generic remote providers.
- **Copy connection string** — copies `remoteAddress` to clipboard.
- **Open settings** — opens remote-specific settings.
- **Show output** — opens the provider's output channel.

Accepts `IShowRemoteHostOptionsOptions.showBackButton` and returns `'back' | undefined`.

If the provider status is `RemoteAgentHostConnectionStatus.incompatible`, the options picker sets a sticky warning validation message before showing the actions. The message includes the protocol version VS Code offered, the versions the remote host reported (when available), and tells the user to update one side. Reconnect is still offered; manual reconnect clears the sticky incompatible state before trying again. Ordinary disconnected/network states keep the existing reconnect behavior and do not show the protocol-version validation banner.

## Session workspace picker inline remove

The session workspace picker (`sessionWorkspacePicker.ts`) shows remote host rows in the Remote tab. Rows with `onRemove` get the shared ActionList close button (`$(close)`) rendered by `actionList.ts`.

Inline remove must use the same `removeRemoteHost(...)` helper as the per-remote options picker. Calling `IRemoteAgentHostService.removeRemoteAgentHost(address)` directly bypasses tunnel-owned disconnect state (including persisted auto-connect suppression), so the X button and "Remove Remote" diverge. The shared ActionList `onRemove` callback is async-aware; await the provider removal before removing the row locally so failures and provider refresh ordering don't get hidden by the UI.

## Manage Remote Agent Hosts (`manageRemoteAgentHosts.ts`)

An F1 command (`workbench.action.sessions.manageRemoteAgentHosts`) that opens a standalone QuickPick showing:

- **"Remote Agent Hosts" separator** + one item per connected/known remote provider (any provider with a `remoteAddress`). Each item has an inline `$(close)` button to remove it.
- **"Add or Manage" separator** + items from `SessionWorkspaceManage` menu actions (SSH..., Tunnels..., etc.) for adding new connections.

The picker is live — it subscribes to `onDidChangeProviders` and each provider's `connectionStatus` observable and refreshes on change, preserving the user's current filter value.

**Back navigation pattern:** when a management action (SSH, Tunnel) is invoked from the manage picker, the picker passes `() => showManagePicker()` as the second argument to `commandService.executeCommand`. The invoked `Action2.run(accessor, onBack?)` receives this callback and passes `{ showBackButton: true }` to its sub-picker, so back-button clicks return to the manage picker.

## `ISSHRemoteAgentHostService` contract

`src/vs/platform/agentHost/common/sshRemoteAgentHost.ts` defines two interfaces:
- `ISSHRemoteAgentHostService` (node-side) — `listSSHConfigHosts()`, `resolveSSHConfig()`, `ensureUserSSHConfig()`, `listSSHConfigFiles()`, etc.
- `ISSHRemoteAgentHostServiceRenderer` (renderer-side passthrough) — same methods, forwarded over IPC.

`ensureUserSSHConfig()` creates `~/.ssh/` and `~/.ssh/config` on demand (with correct POSIX permissions), then returns the URI. It **throws** if directory creation or file creation fails — callers can catch and surface the error to the user. It does NOT silently swallow errors and return a non-existent path.

## QuickPick disposable pattern

All pickers in this module follow the same lifecycle:

```typescript
const store = new DisposableStore();
const picker = store.add(quickInputService.createQuickPick<T>());
// register all listeners inside the store:
store.add(picker.onDidTriggerButton(...));
store.add(picker.onDidAccept(() => { resolve(...); picker.hide(); }));
store.add(picker.onDidHide(() => { resolve(undefined); store.dispose(); }));
picker.show();
```

The `store.dispose()` inside `onDidHide` ensures the picker and all event subscriptions are cleaned up regardless of how the picker closes (back button, Escape, accept, focus-lost). **Do not call `picker.dispose()` inside `onDidAccept`** — that fires before `onDidHide`, and disposing there will then fire `onDidHide` after the `store` is already gone. Call `picker.hide()` from `onDidAccept` and let `onDidHide` do the cleanup.

## `setTimeout` between pickers

**No `setTimeout` is needed** when transitioning from one `createQuickPick`-based picker to another. Call `picker.hide()` and immediately show the new picker — the framework sequences them correctly.

The one **legitimate exception** is transitioning from `actionWidgetService.hide()` to showing a QuickPick. The action widget has async DOM/focus teardown; without a tick defer, the QuickPick can appear behind the widget overlay. In that case a `setTimeout(fn, 0)` is correct and should carry a comment explaining why.

## Debt & gotchas

- **gotcha** (2026-05-02, sessionWorkspacePicker.ts:onRemove + remoteHostOptions.ts:removeRemoteHost) — the workspace-picker X and "Remove Remote" must call the same helper. Do NOT call `IRemoteAgentHostService.removeRemoteAgentHost` directly from the X; tunnel providers need their `provider.disconnect()` hook to persist the user's disconnect intent and suppress future auto-connect.
- **gotcha** (2026-04-26, remoteAgentHostActions.ts:promptToConnectViaSSH) — there is no "Enter manually" static entry; the dynamic new-host item is synthesized from the current input. Do NOT re-add a static placeholder. The pattern mirrors Remote SSH extension behavior deliberately.
- **gotcha** (2026-04-26, remoteAgentHostActions.ts:onDidAccept) — call `picker.hide()` inside `onDidAccept`, not `picker.dispose()`. `dispose()` inside `onDidAccept` triggers `onDidHide` twice-ish and causes double-resolve or double-dispose. The `DisposableStore` pattern in `onDidHide` handles all cleanup.
- **gotcha** (2026-04-26, manageRemoteAgentHosts.ts:buildItems) — the "Remote Agent Hosts" separator header shows items regardless of `connectionStatus` — including Offline/Connecting. Do NOT rename it to "Connected" without also filtering to `connectionStatus === 'Connected'`.
- **gotcha** (2026-04-26, remoteAgentHostActions.ts:configureSSHHosts run + promptToConnectViaSSH) — back-button callbacks propagate via `commandService.executeCommand(id, onBack)`. The `Action2.run(accessor, onBack?)` receives the callback as the second arg. All actions in this module that can be invoked both directly (no back button) and from a parent picker (with back button) follow this pattern. Do not move to a service/context — the callback captures the parent picker's closure.

## Changelog

- **2026-05-15** — 12443ea83d — reconciliation: updated provider paths after `a3d955d72ad` and refreshed the remote-tab/tunnel picker behavior touched by `a512727d3c6`, `f505d201296`, `63a4d486a04`, `e5ebfeb5eb3`, and `cb383df993c`.

- **2026-05-04** — 939d3f227c — reconciliation: documented the incompatible-protocol validation banner and manual reconnect behavior from `e1a89568eb2`; no body change needed for mobile workspace-picker layout polish in `2fc10e36d28` beyond existing picker semantics.

- **2026-05-02** — `b61ea2452e` — documented the shared remote-host remove/reconnect helpers, workspace-picker inline X semantics, and the async ActionList remove path needed for tunnel-backed providers.
- **2026-04-26** — `eb9ae3f827` — initial entry: SSH picker UX (dynamic new-host item, footer items, no "Enter manually"), Configure SSH Hosts file picker, tunnel picker, per-remote options, standalone manage picker, back-button threading, DisposableStore pattern, `ensureUserSSHConfig` throw-on-error contract.
