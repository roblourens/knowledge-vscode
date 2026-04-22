# Reconcile Agent Host Knowledge Docs

**Date:** 2026-04-21
**VS Code branch:** main
**VS Code SHA at finalize:** 0a84983bc1
**PR:** TBD

## What was done

Reconciled the Agent Host knowledge docs against current VS Code `origin/main` at `ad531180d0`. The pass used each doc's latest changelog baseline to limit the code audit to covered areas that actually changed, then ran a mechanical source-path existence check across the docs and index.

The docs were updated for the new workbench permission-picker extension-permission hooks, the `AgentHostChatSession.dispose()` ordering fix, the Agents-app remote host filter/scoping layer, and two stale moved path references. A malformed changelog entry in `copilot-agent-provider.md` was also repaired so future reconcile runs can parse the baseline cleanly.

## Key decisions

- Used `origin/main` as the reconcile target, matching the normal knowledge workflow for the main VS Code checkout.
- Treated `9a5b0119f0c`'s permission-picker extension callbacks as workbench-only behavior rather than broadening the AHP `autoApprove` contract; the agent-host delegate remains focused on the well-known session-config value.
- Added remote host scoping to the topology doc rather than the sessions-provider doc because the behavior is Agents-app chrome that scopes list/workspace surfaces above the protocol connection layer.
- Preserved the existing debt entries during reconcile. None of the audited commits clearly resolved the underlying debt.

## What went wrong or was misunderstood

- The automatic init script resolved the knowledge repo as the `skills/init` folder and created `.knowledge` pointing at a nested worktree path. The checkout still functioned as a worktree of the knowledge repo, but the path was surprising. — **prevented by:** this summary; the init skill/script should be revisited separately so it resolves the root knowledge repo from the skill path reliably.
- The first baseline scan used the last physical changelog entry, but several docs had changelog entries out of chronological order. That produced noisy commit ranges. — **prevented by:** the reconcile run switched to the newest dated changelog entry before deciding which docs drifted.
- A brute-force symbol check used repeated repo-wide `rg` calls and timed out. — **prevented by:** this summary; future reconcile runs should use targeted symbol checks after the path and commit-range pass, not a broad nested grep loop.
- Upstream knowledge `main` moved after this session started, and the required fast-forward sync initially failed because uncommitted local edits overlapped three upstream-edited docs. — **prevented by:** this summary; the safe recovery was to stash local edits, fast-forward to `origin/main`, and replay the stash, preserving the upstream audit entry before finalizing.
- Existing docs contained malformed changelog entries that made baseline parsing fragile. — **prevented by:** repaired entries in `agent-host-session-handler.md` and `copilot-agent-provider.md`.

## What we learned

- `PermissionPickerActionItem` now supports optional extension-contributed permission groups, but that remains separate from the agent-host `autoApprove` convention.
- `AgentHostChatSession.dispose()` intentionally overrides disposal so `onWillDispose` fires before registered disposables are torn down; the previous `_register(toDisposable(...))` shape fired too late for chat-session cache eviction.
- The Agents app's remote host filter is app-level chrome: it persists a selected remote provider id and scopes the sessions list and workspace picker without changing AHP protocol state.
- Mechanical path checks are valuable during reconcile; they found both the moved `protocol/sessionConfig.integrationTest.ts` path and the generic picker's `agentHost/` subfolder.

## Doc updates

- `docs/agent-host-auto-approve-picker.md` — documented the workbench-only extension permission delegate callbacks and added a reconciliation changelog entry.
- `docs/agent-host-session-handler.md` — documented the deliberate `AgentHostChatSession.dispose()` ordering and added a gotcha.
- `docs/agent-host-topology.md` — added the remote host filter/scoping section and expanded `Covers:`.
- `docs/agent-host-sessions-providers.md` — fixed stale references to moved session-config picker/test paths.
- `docs/copilot-agent-provider.md` — repaired a malformed changelog entry and added a reconciliation baseline entry.
- `index.md` — synchronized the topology doc summary and `Covers:` list.