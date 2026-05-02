# Local agent host respects parent's `--user-data-dir`

**Date:** 2026-05-01
**VS Code branch:** roblou/agents/custom-user-data-dir-support
**VS Code SHA at finalize:** 4c1428f072
**PR:** [#313827](https://github.com/microsoft/vscode/pull/313827)

## What was done

`ElectronAgentHostStarter` and `NodeAgentHostStarter` now forward the parent process's resolved `userDataPath` to the spawned agent host child as `--user-data-dir <path>` (alongside the already-forwarded `--logsPath`). Inside `agentHostMain.ts`, `parseArgs(process.argv, OPTIONS)` therefore resolves the same `userDataPath` the parent app was launched with, so all host-owned state (`SessionDataService`'s `{userData}/agentSessionData/`, `AgentPluginManager`'s `{userData}/agentPlugins/`, and the root `agent-host-config.json` under `appSettingsHome`) lives inside the parent's custom user-data dir.

## Key decisions

- **Argv forwarding rather than payload config.** The agent host already consumes `--logsPath` via argv; adding `--user-data-dir` plugs straight into the existing pattern with no new plumbing. The shared-process / extension-host style of passing a structured config payload (`SharedProcess.createSharedProcessConfiguration`, `localProcessExtensionHost`) would be a bigger refactor and isn't needed here.
- **Did not rely on Electron's built-in `--user-data-dir` propagation.** Electron does propagate the flag to its own child processes for `app.getPath('userData')`, but VS Code's `parseArgs`-derived `userDataPath` is independent of that — the explicit argv pass is required.

## What went wrong or was misunderstood

- Initial assumption was that the agent host inherited the parent's `userDataPath` somehow (Electron flag propagation, env var, or implicit IPC). The reality is that `agentHostMain.ts` builds its own `NativeEnvironmentService` from scratch via `parseArgs(process.argv)`, and the starters were only forwarding `--logsPath`. — **prevented by:** new gotcha on `agent-host-topology.md` ("the spawned local agent host process derives its `userDataPath` from `parseArgs(process.argv)` … the starters explicitly forward `--user-data-dir`").
- The doc body at `agent-host-topology.md` already correctly says the metadata layer lives "under the host's `userDataPath`" — but that phrasing reads as a fact about the host, not as a constraint on whoever spawns it. The new gotcha makes the constraint explicit so a future starter (e.g. a new sandboxed/remote/test launcher) doesn't silently regress.

## What we learned

- There are two parallel patterns for handing config to a spawned VS Code child process: argv (used here, and by `--logsPath`) and a structured `payload` over IPC (used by shared process and extension host). Worth knowing which one a given starter is on before adding new fields.

## Doc updates

- `docs/agent-host-topology.md`: added one **gotcha** entry under `## Debt & gotchas` covering the `--user-data-dir` forwarding requirement for local AH starters, and a corresponding changelog bullet.
