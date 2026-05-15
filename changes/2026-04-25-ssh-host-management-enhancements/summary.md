# SSH Host Management Enhancements for the Agents App

**Date:** 2026-04-26
**VS Code branch:** roblou/agents/ssh-host-management-enhancements
**VS Code SHA at finalize:** eb9ae3f827
**PR:** [#312630](https://github.com/microsoft/vscode/pull/312630)

## What was done

Rewrote and extended the remote agent host management UX in the Agents app across three related areas:

1. **SSH connection picker** — Rewrote `promptToConnectViaSSH` to mirror the Remote SSH extension's UX: SSH config aliases shown as static items, a dynamic synthetic "new host" item synthesized from free-form input (matching `user@host` or `user@host:port`), and footer items for "Add New SSH Host" and "Configure SSH Hosts". Removed the old static "Enter manually" entry.

2. **Inline remove buttons in Workspace picker Manage submenu** — Added inline `$(close)` buttons next to SSH and tunnel entries in the `sessionWorkspacePicker`'s Manage submenu, matching the behavior of recently-opened folder items at the top level.

3. **"Manage Remote Agent Hosts" F1 command** — Added a standalone command (`manageRemoteAgentHosts.ts`) that opens a live-refreshing QuickPick listing all known remote hosts (with inline remove buttons) and menu actions for adding new connections. Back-button navigation threads through the entire picker hierarchy: manage → SSH → configure file picker, and manage → tunnels.

Also added:
- `listSSHConfigFiles()` to `ISSHRemoteAgentHostService` so the "Configure SSH Hosts" action can list all SSH config files (user + system).
- `RemoteAgentHostCommandIds` const block to avoid hardcoded command ID strings.
- `DisposableStore` wrapping for all QuickPick pickers to prevent leaked disposables.

## Key decisions

- **No "Enter manually" entry.** The Remote SSH extension doesn't have one — it uses a dynamic synthetic item that appears as you type. Matching that UX means users who know the Remote SSH extension get the same muscle memory in the Agents app.
- **Back callbacks via `executeCommand` second arg.** Back-button navigation between pickers is threaded via `commandService.executeCommand(id, () => showManagePicker())`. The invoked `Action2.run(accessor, onBack?)` receives the callback as the second arg and passes `{ showBackButton: true }` to sub-pickers. This avoids any shared service or context coupling — the callback captures the parent picker's closure.
- **No `setTimeout` between pickers.** `createQuickPick`-based transitions don't need a tick defer. Only the `actionWidgetService.hide()` → QuickPick transition needs one (async DOM/focus teardown).
- **`ensureUserSSHConfig` rethrows on failure.** Callers rely on this method to ensure the file is there and openable. Swallowing errors and returning a URI to a non-existent file would cause silent failures in "Add New SSH Host". Now throws, so UI can surface real errors.
- **"Remote Agent Hosts" separator header.** Items in the manage picker are not filtered by connection status (they include Offline/Connecting), so the header says "Remote Agent Hosts" not "Connected".

## What went wrong or was misunderstood

- **Wrong service-injection pattern.** Initially passed services as constructor arguments to `showRemoteHostOptions` instead of using `ServicesAccessor`. VS Code's pattern is to receive `ServicesAccessor` in `Action2.run()` or `invokeFunction` — **prevented by:** general VS Code coding guidelines (already in project instructions); no knowledge-base entry added because this is in the existing copilot-instructions.

- **`setTimeout` between pickers.** Used `setTimeout(fn, 0)` to defer showing the next picker after hiding the current one, copying a pattern from `quickInputService.pick`-based code. Not needed with `createQuickPick`. **prevented by:** new doc [remote-agent-host-management-ux#settimeout-between-pickers](../docs/remote-agent-host-management-ux.md#settimeout-between-pickers).

- **Leaked disposables in QuickPick pickers.** `onDidAccept` and `onDidHide` were added outside any `DisposableStore`, causing the GC-based disposable tracker to report leaks. The fix is always to `store.add(picker.onDidX(...))` and dispose the store in `onDidHide`. **prevented by:** new doc [remote-agent-host-management-ux#quickpick-disposable-pattern](../docs/remote-agent-host-management-ux.md#quickpick-disposable-pattern).

- **Calling `picker.dispose()` inside `onDidAccept`.** Causes `onDidHide` to fire after dispose, double-resolving the promise. Always call `picker.hide()` from `onDidAccept` and let `onDidHide` do the cleanup. **prevented by:** new gotcha in [remote-agent-host-management-ux#debt--gotchas](../docs/remote-agent-host-management-ux.md#debt--gotchas).

- **"Configure SSH Hosts" doing nothing.** The action was registered but had no implementation for listing config files and showing the picker. The `listSSHConfigFiles()` method was missing from `ISSHRemoteAgentHostService`. **prevented by:** doc coverage; the gap was simply not documented. Now covered in [remote-agent-host-management-ux](../docs/remote-agent-host-management-ux.md#configure-ssh-hosts-picker).

- **Back button only on top-level picker.** Initially only the SSH picker had a back button. Configure SSH Hosts and the Tunnel picker lacked them. The threading of `onBack` callbacks through `commandService.executeCommand` second-arg was the missing insight. **prevented by:** new doc [remote-agent-host-management-ux#back-navigation-pattern](../docs/remote-agent-host-management-ux.md#manage-remote-agent-hosts-manageremoteagenthostsTs).

- **"Connected" separator label (Copilot review).** Named the separator "Connected" but items are not filtered by `connectionStatus`. Caught by Copilot PR review. Fixed to "Remote Agent Hosts". **prevented by:** new gotcha in [remote-agent-host-management-ux#debt--gotchas](../docs/remote-agent-host-management-ux.md#debt--gotchas).

- **`ensureUserSSHConfig` swallowing errors (Copilot review).** The method logged errors and returned a URI to a potentially non-existent file. Caught by Copilot PR review. Fixed to rethrow. **prevented by:** new contract description in [remote-agent-host-management-ux#isshremoteagenthostservice-contract](../docs/remote-agent-host-management-ux.md#isshremoteagenthostservice-contract).

- **Build mechanism confusion.** Initially tried `tsc` and `esbuild` directly. The correct command is `npm run compile` (runs gulp), which outputs to `out/vs/`. `npm run compile-check-ts-native` is type-check only (no JS output). **prevented by:** this is partially in [testing](../docs/testing.md) but the specific `npm run compile` → gulp relationship could be clearer there.

## What we learned

- The Remote SSH extension (`../vscode-remote-ssh`) is the right reference implementation for SSH UX patterns. When in doubt, match it.
- `quickInputService.pick()` (promise-based wrapper) has different transition semantics from `createQuickPick()`. The former needs `setTimeout`; the latter does not. Prefer `createQuickPick` for anything that needs back buttons or fine-grained control.
- `Action2.run(accessor, ...args)` can receive extra args beyond the accessor. Passing callbacks as extra args is the clean way to thread back-navigation between actions without introducing shared services or context state.

## Doc updates

- **Created** `docs/remote-agent-host-management-ux.md` — SSH picker UX, Configure SSH Hosts, tunnel picker, per-remote options, manage picker, back-button pattern, DisposableStore pattern, `setTimeout` guidance, `ensureUserSSHConfig` contract. Added 4 gotchas.
- **Updated** `index.md` — added entry for the new doc under Docs.
