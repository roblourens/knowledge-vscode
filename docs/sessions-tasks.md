# Sessions tasks (Agents-app `inAgents` tasks.json)

_Covers: src/vs/sessions/contrib/chat/browser/sessionsTasksService.ts, src/vs/sessions/contrib/chat/browser/sessionTaskRunner.ts, src/vs/sessions/contrib/chat/browser/workbenchSessionTaskRunner.ts, src/vs/sessions/contrib/chat/browser/registerDefaultSessionTaskRunners.ts, src/vs/sessions/contrib/chat/browser/worktreeCreatedTaskDispatcher.ts, src/vs/sessions/contrib/terminal/browser/agentHostSessionTaskRunner.ts_

The Agents app has a parallel "session tasks" concept on top of plain `tasks.json`: tasks marked `inAgents: true` are surfaced in the session chat toolbar's task picker, and the subset tagged `runOptions.runOn === 'worktreeCreated'` is auto-dispatched once per newly created session worktree (e.g. `npm install`, `bundle install`, project setup commands). Manual `Run Task` invocations from the toolbar are unaffected by the auto-dispatch.

## Roles

The subsystem splits cleanly into three roles:

1. **Discovery & storage** — `SessionsTasksService` (`sessionsTasksService.ts`). Reads/writes workspace and user `tasks.json` via `IFileService` and `IJSONEditingService`. Provides `getSessionTasksOnce(session)` (one-shot snapshot), `getSessionTasks(session)` (observable, single-follower — see the JSDoc warning), `getAllTasks(session)` (no `inAgents` filter; used by runners to resolve `dependsOn`), and CRUD helpers (`addTaskToSessions`, `createAndAddTask`, `updateTask`, `removeTask`). Path resolution uses `session.workspace.get()?.folders[0]?.workingDirectory ?? root` so it works whether the session is backed by a worktree (preferred), a plain repo, or — for agent-host sessions — a remote `agent-host:` URI handled via a file provider.

2. **Execution dispatch** — `ISessionTaskRunnerRegistry` + `ISessionTaskRunner` (`sessionTaskRunner.ts`). Pluggable runners with a priority field. `ISessionsTasksService.runTask(task, session)` consults the registry and picks the highest-priority runner whose `canRun(session)` returns `true`. Two runners are registered at startup via `registerDefaultSessionTaskRunners.ts`:
   - `WorkbenchSessionTaskRunner` (priority `0`, `id: 'workbench'`) — delegates to `ITaskService.run`. Only `canRun` for `file://` sessions whose folder is currently loaded into the workbench workspace.
   - `AgentHostSessionTaskRunner` (priority `100`, `id: 'agentHost'`, lives under `contrib/terminal/`) — resolves the task into a shell command via `resolveTaskCommand` (which expands `dependsOn` ordering), then opens a terminal via `IAgentHostTerminalService.createTerminalForEntry` on either `__local__` or `provider.remoteAddress`. `canRun` returns true iff `session.providerId` resolves to an agent-host provider.

3. **Auto-dispatch on worktree creation** — `WorktreeCreatedTaskDispatcher` (`worktreeCreatedTaskDispatcher.ts`). Workbench contribution that subscribes to `ISessionsManagementService.onDidChangeSessions`, tracks newly added sessions (and the pending-→-committed handoff for `Untitled` sessions), waits until the session reports an actual worktree (`session.workspace.read(reader)?.folders.some(folder => folder.gitRepository?.workTreeUri)`), and then calls `_sessionsTasksService.runTask(task, session)` once per task tagged `runOptions.runOn === 'worktreeCreated'`. Sessions whose runtime already runs these tasks itself (`session.capabilities.runsWorktreeCreatedTasks`) are skipped to avoid double-execution.

## Why two execution paths for agent-host

Task **discovery** is shared (read `tasks.json` via `IFileService`). Task **execution** branches by session type because the workbench `ITaskService` only knows about folders that are loaded into the local workbench workspace — that's never the case for an agent host session, whose worktree lives on a different host (or under `agent-host:` even when local). So `AgentHostSessionTaskRunner` bypasses `ITaskService` entirely and instead manufactures a shell command, opens an agent-host terminal at the session's cwd (unwrapping `agent-host:` → file path via `fromAgentHostUri`), and sends the resolved command line. This is the reason the priority field exists at all — to let the agent-host runner take priority over the workbench fallback when both `canRun`.

## Gating worktreeCreated auto-dispatch

`WorktreeCreatedTaskDispatcher` gates auto-dispatch for **agent-host sessions only** via the `chat.agentHost.runWorktreeCreatedTasks` setting (default `false` while related issues are being addressed). The gate is in the dispatcher (not the runner) on purpose: gating in the runner would also break manual `Run Task` from the toolbar, which is the only way users currently run these tasks on agent-host sessions. The check uses `isAgentHostProviderId(session.providerId)` (a pure string predicate over `LOCAL_AGENT_HOST_PROVIDER_ID` / `REMOTE_AGENT_HOST_PROVIDER_PREFIX`) — no `ISessionsProvidersService` lookup needed, because the gate is decided entirely by the well-known provider ID prefix.

## Tests

Tests live alongside the production code:

- `src/vs/sessions/contrib/chat/test/browser/worktreeCreatedTaskDispatcher.test.ts` — covers the dispatch lifecycle (added-vs-restored, pending-untitled handoff, loading flicker, per-session isolation, capability-skip, agent-host gate).
- `src/vs/sessions/contrib/terminal/test/browser/agentHostSessionTaskRunner.test.ts` — covers the runner.
- The `SessionsTasksService` itself has additional coverage near `sessionsTasksService.ts`.

## Debt & gotchas

- **gotcha** (2026-05-25, `worktreeCreatedTaskDispatcher.ts:_trackSession`) — `_trackSession` returns early via `_isPendingWorktreeSession` unless the session is currently `Untitled`, still loading, OR has no worktree. Tests that want to exercise the dispatch path must construct a session with `hasWorktree: false`, fire the `added` event, then assign the workspace; constructing a session that already has a worktree and firing `added` will silently skip dispatch. The 3 setting-gate tests added in `faab40636a1` originally hit this and one passed by coincidence (it asserted on an empty `ranTasks`).
- **gotcha** (2026-05-25, `worktreeCreatedTaskDispatcher.ts:_dispatchWorktreeCreatedTasks`) — the agent-host gate uses `isAgentHostProviderId(session.providerId)`, not `isAgentHostProvider(provider)`. Don't reintroduce an `ISessionsProvidersService` lookup here — the check is fully decidable from the well-known provider ID prefix, and looking up the provider would silently let auto-dispatch through if the provider were momentarily unregistered.
- **debt** (2026-05-25, `chat.agentHost.runWorktreeCreatedTasks`) — the setting default is `false` while underlying issues are being addressed. Flip back to `true` (or remove the gate entirely) once the dispatch behavior is reliable for agent-host sessions.

## Changelog

- **2026-05-25** — faab40636a — initial doc; documents the three roles (discovery, dispatch registry, worktree-created auto-dispatch), the agent-host execution split, the `chat.agentHost.runWorktreeCreatedTasks` gate added in PR #318243, and the `_trackSession` early-bail gotcha that breaks dispatcher tests.
