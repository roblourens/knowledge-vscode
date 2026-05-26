# Disable worktreeCreated tasks by default for agent-host sessions

**Date:** 2026-05-25
**VS Code branch:** agents/vsckb-implement-connor-recently-added-this-featu-045d19df
**VS Code SHA at finalize:** faab40636a
**PR:** [#318243](https://github.com/microsoft/vscode/pull/318243)

## What was done

Added `chat.agentHost.runWorktreeCreatedTasks` (boolean, application-scoped, **default `false`**) and wired it into `WorktreeCreatedTaskDispatcher` so that — for agent-host sessions only — auto-dispatching `runOptions.runOn === 'worktreeCreated'` tasks is gated by the setting. Manual `Run Task` from the toolbar and non-agent-host sessions are unaffected. The gate uses a new pure-string helper `isAgentHostProviderId(providerId)` in `agentHostSessionsProvider.ts` so the dispatcher does not depend on `ISessionsProvidersService`.

Three new unit tests cover the gate (default-off skips agent-host, on runs it, non-agent-host always runs). All other dispatcher tests are unchanged.

## Key decisions

- **Gate in the dispatcher, not the runner.** The runner (`AgentHostSessionTaskRunner`) is also the path used by manual `Run Task` from the toolbar; gating there would disable the only way users currently run these tasks on agent-host sessions. The dispatcher is the auto-run-only entry point and is therefore the correct seam.
- **Agent-host-only gate.** User explicitly pushed back on a generic `sessions.worktreeCreatedTasks.enabled` setting; non-agent-host (workbench-backed) sessions are unaffected and continue to auto-run.
- **Pure provider-ID predicate, no service injection.** After review feedback from Copilot, replaced `ISessionsProvidersService.getProvider(id)` + `isAgentHostProvider(provider)` with a new `isAgentHostProviderId(id)` helper. The gate is fully decidable from the well-known provider ID prefix (`local-agent-host` / `agenthost-*`); the provider lookup added a dependency and could let auto-dispatch through if the provider were momentarily unregistered.
- **Default `false` (escape hatch is to flip the setting on).** The feature has known bugs that the team wants to triage before re-enabling broadly.
- **Setting description uses `"runOptions": { "runOn": "worktreeCreated" }`** to match the actual `tasks.json` JSON shape (reviewer caught this).

## What went wrong or was misunderstood

- **CI failed on 2 of 3 new tests because they bypassed the gate entirely.** `WorktreeCreatedTaskDispatcher._trackSession` returns early via `_isPendingWorktreeSession` unless the session is `Untitled`, loading, or has no worktree. My new tests built sessions with `hasWorktree: true` (default) and fired the `added` event, so dispatch never started and the setting gate was never exercised. Test #1 ("skip") passed by coincidence (empty `ranTasks` matched expected). Every existing test in the file uses the opposite pattern (start `hasWorktree: false`, fire `added`, then set the workspace), but I didn't notice. **Prevented by:** a `gotcha:` entry in the new [sessions-tasks](../../docs/sessions-tasks.md) doc pointing at this exact early-bail in `_trackSession`, plus the changelog entry naming the failure mode.
- **Initial design proposed gating in the runner.** I had to be redirected to the dispatcher seam, and again to the agent-host-only scope. **Prevented by:** the new doc explicitly explains why the gate lives in the dispatcher (manual Run Task uses the runner) and why the scope is agent-host-only (workbench-backed sessions work fine today).
- **Added an unnecessary `ISessionsProvidersService` injection.** First version of the dispatcher gate looked up the provider and called `isAgentHostProvider(provider)` even though that helper only inspects `provider.id`. Reviewer caught this; I added `isAgentHostProviderId(providerId)` and dropped the lookup. **Prevented by:** the new `isAgentHostProviderId` export + the gotcha entry in [sessions-tasks](../../docs/sessions-tasks.md) saying "don't reintroduce a provider lookup here."
- **`gh pr create --body "$(cat <<EOF ...)"` mangled backticks in the PR body.** Switched to `--body-file <path>` from the session-files area. **Prevented by:** a user-level memory captured via `store_memory`.
- **No existing knowledge doc covered the sessions-tasks subsystem at all.** I had to discover from code that discovery is shared (`SessionsTasksService`) while execution branches by session type via a priority-based runner registry, and that `WorktreeCreatedTaskDispatcher` is the auto-run entry point. **Prevented by:** new [sessions-tasks](../../docs/sessions-tasks.md) doc.

## What we learned

- The architecture Connor introduced in PR #317186 splits tasks cleanly: discovery in `SessionsTasksService` is already agent-host-compatible (works through the file provider for `agent-host:` URIs), and `ISessionTaskRunnerRegistry` lets `AgentHostSessionTaskRunner` claim agent-host sessions at priority `100` over `WorkbenchSessionTaskRunner` at priority `0`. The split exists precisely because the workbench `ITaskService` only handles folders loaded into the local workbench workspace.
- `TestConfigurationService.getValue` returns `undefined` for unset settings, which boolean-coerces to `false` and happens to match the production default — so tests don't need to explicitly seed the setting unless they want a non-default value. Awaiting `setUserConfiguration` is defensive for if/when the helper becomes async.

## Doc updates

- New: [docs/sessions-tasks.md](../../docs/sessions-tasks.md). Covers discovery vs dispatch vs auto-dispatch, the runner priority pattern, why agent-host needs a separate runner, the worktreeCreated gating decision, and `_trackSession`'s pending-only early-bail (the gotcha that caused the CI test failure).
- Updated: [index.md](../../index.md) — added new doc to the **Docs** list.
- Debt & gotchas added (in the new doc):
  - **gotcha** — `WorktreeCreatedTaskDispatcher._trackSession` early-bail (tests must start with no worktree and add one).
  - **gotcha** — agent-host gate uses `isAgentHostProviderId(providerId)`, not a provider lookup; don't reintroduce the lookup.
  - **debt** — `chat.agentHost.runWorktreeCreatedTasks` default is `false` while issues are being addressed; flip back to `true` (or remove gate) once dispatch is reliable.
