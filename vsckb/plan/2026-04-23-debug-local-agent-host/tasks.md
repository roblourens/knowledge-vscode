# Debug Local Agent Host Process In Dev Tools

Add a `Developer: Debug Local Agent Host Process In Dev Tools` command, modeled
after the existing `Debug Extension Host In Dev Tools` action, that opens a
Chrome DevTools window attached to the agent host utility process.

## Tasks

- [x] Add `IAgentHostInspectInfo` and `getInspectInfo(tryEnable)` on
      `IConnectionTrackerService` and `IAgentHostService` in
      `src/vs/platform/agentHost/common/agentService.ts`.
- [x] Implement `getInspectInfo` in `agentHostMain.ts` using `node:inspector`
      (`inspector.url()` to read, `inspector.open(0, '127.0.0.1', false)` to
      enable). Parse `ws://host:port/uuid` and build the
      `devtools://devtools/bundled/js_app.html?v8only=true&ws=...` URL —
      same shape used by the extension-host code path.
- [x] Forward through the renderer-side `AgentHostServiceClient` and
      stub it on `NullAgentHostService` (returns `undefined`).
- [x] Register `DebugAgentHostInDevToolsAction` in
      `src/vs/workbench/contrib/chat/electron-browser/actions/chatDeveloperActions.ts`
      under `Categories.Developer`. Calls `getInspectInfo(true)`, then
      `INativeHostService.openDevToolsWindow`. Notifies on failure.
- [x] `npm run compile-check-ts-native` passes.

## Notes / design choices

- Inspector lives **inside the utility process**, not the main process, so we
  use `node:inspector` from `agentHostMain.ts` rather than wiring a new
  main-process IPC channel + parsing stderr the way the extension host does.
  This avoids needing a new main IPC service for the agent host starter.
- `inspector.open(0, '127.0.0.1', false)` picks a random local port and does
  not block startup. `127.0.0.1` matches what extension host effectively binds
  to (and avoids exposing the inspector publicly).
- Hangs the new method off `IConnectionTrackerService` because it's
  process-infra-level (peer of `startWebSocketServer`), not part of the AHP
  agent surface.
- No restart-required prompt (unlike the extension-host action): we can enable
  the inspector live on the running process via `inspector.open`, so there's
  nothing to restart.

## Discoveries for finalize

- (none — clean implementation, no doc drift detected)
