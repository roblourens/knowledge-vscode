# Fix Agent Host worktree metadata timing

**Date:** 2026-07-03
**VS Code branch:** agents/worktree-info-delay-fix
**VS Code SHA at finalize:** 46620a421f
**PR:** https://github.com/microsoft/vscode/pull/324280

## What was done

Fixed Agent Host worktree sessions so the agent window receives their final workspace and Git identity as soon as materialization makes it available. `notify/sessionAdded` now upserts an existing provisional adapter instead of ignoring the duplicate raw ID, list aggregation overlays live project/working-directory metadata over provider snapshots, and remote providers persist the updated adapter metadata.

Git-state refreshes are now suppressed centrally while a session is in the `Creating` lifecycle. A provisional session's temporary working directory is the selected checkout; after materialization transitions it to the final worktree, the normal Git refresh publishes the real branch through `SessionMetaChanged` and `SessionSummaryChanged`. Focused unit tests cover the host lifecycle, stale provider-list snapshots, local adapter updates, metadata notifications, and remote cache persistence.

## Key decisions

- Put the provisional lifecycle guard in `AgentHostGitStateService.refreshSessionGitState`, not in individual subscribe/turn/file-monitor callers. The state service owns the invariant that Git truth is valid only after the final working directory exists.
- Keep `sessionAdded` and Git metadata as two ordered updates: materialization publishes project/worktree immediately, then the Git probe publishes branch state. Do not block `sessionAdded` on shelling out to Git.
- Preserve `AgentHostSessionAdapter` identity during draft-to-materialized updates. The agent window already owns references to that adapter; replacing it would create unnecessary removal/replacement behavior.
- Fix stale list data at the server aggregation boundary by overlaying live `modifiedAt`, `project`, and `workingDirectory`, rather than adding client-side version maps and tombstones.

## What went wrong or was misunderstood

- Initially assumed the branch appeared only at turn completion because the provider discarded materialized `sessionAdded` data. The provider did discard workspace updates, but AHP logs showed the final branch is a separate later `SessionSummaryChanged`. — **prevented by:** expanded lifecycle descriptions in `agent-host-sessions-providers` and `agent-host-git-driven-diffs`.
- Added a per-session metadata-version/tombstone map to defend against a hypothetical stale `listSessions()` response. This was complex and did not explain the observed run. The eventual race defense belongs in `AgentService.listSessions`, which can overlay authoritative live workspace fields. — **prevented by:** the new `sessionAdded` upsert gotcha and the Git-state lifecycle section.
- Interpreted a 47-second AHP gap as slow Git computation. Debugger logpoints showed the Git probe itself completed in 40–150ms; the earlier trace had debugger/process scheduling effects and did not identify the compute cost. — **prevented by:** this summary's runtime-validation narrative; use AHP wire timestamps together with Agent Host logpoints before attributing latency to a service.
- First placed the `Creating` guard only in `AgentService.subscribe`. Turn completion and file-monitor callers could still probe the temporary checkout. — **prevented by:** the `refreshSessionGitState` gotcha in `agent-host-git-driven-diffs`.
- Initial provider tests were too broad and characterized action and summary paths separately without pinning the real sequence. They were reduced to the materialization upsert plus metadata update flow, while lifecycle ownership is tested directly in `AgentHostGitStateService`. — **prevented by:** testing at the layer that owns each contract, as already stated in `design-principles`.

## What we learned

- A provisional session can be list-visible once a turn starts even though it still has lifecycle `Creating`; list visibility does not mean its workspace or Git identity is final.
- In the validated flow, `sessionAdded` carried the worktree path with no stale Git metadata, and the correct `agents/...` branch arrived through `sessionSummaryChanged` about 185ms later, before turn completion.
- DAP logpoints plus the launch skill and AHP JSONL logs are an effective way to correlate host call sites, computation duration, and client-visible wire ordering without committing temporary logging.

## Doc updates

- `docs/agent-host-git-driven-diffs.md` — added provisional Git-state lifecycle, list-overlay ordering, the centralized `Creating` guard gotcha, Covers paths, and changelog.
- `docs/agent-host-sessions-providers.md` — added authoritative `sessionAdded` upsert, Git metadata follow-up, remote persistence, gotcha, debt refresh, and changelog.
- `index.md` — updated Git doc description/Covers and added the cross-cutting provisional worktree metadata pointer.
