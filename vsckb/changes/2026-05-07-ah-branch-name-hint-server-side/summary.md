# Derive worktree branch name hint from first message on the agent host

**Date:** 2026-05-07
**VS Code branch:** agents/be796a2d-16df-47b0-a4a1-1cc99853564a
**VS Code SHA at finalize:** d116f50c33
**PR:** [#315065](https://github.com/microsoft/vscode/pull/315065)

## What was done

Remote Agent Host sessions in `worktree` isolation mode were generating branches named just `agents/<sessionId>` because the eager-create path (`BaseAgentHostSessionsProvider.eagerCreate` → `connection.createSession`) never sent a `branchNameHint` config — only the legacy create-on-send path in `AgentHostSessionHandler` did. Rather than plumb the hint through the new path on the client, branch-name derivation was moved to the agent host: `_materializeProvisional(sessionId, prompt)` now forwards the prompt to `_resolveSessionWorkingDirectory(config, sessionId, prompt)`, which calls a new `getCopilotBranchNameHintFromMessage(prompt)` slugger. The client no longer derives or sends a hint at all; `SessionConfigKey.BranchNameHint` and the workbench-side `getAgentHostBranchNameHint` helper were deleted.

## Key decisions

- **Server-side derivation, not client-side plumbing.** The provisional session is materialized on first `sendMessage`, which already carries the prompt, so the AH has everything it needs locally. Pushing the slugger to the client would require every transport (local, SSH, tunnel, web, future ones) to mirror the same algorithm and stay in lockstep.
- **Slug rules preserved verbatim.** `getCopilotBranchNameHintFromMessage` reuses the exact NFKD-normalize / lowercase / `[^a-z0-9]+` strip / 8-word / 48-char algorithm from the old client-side helper. No behavioral drift; just a relocation. (NFKD decomposes accents and folds compatibility characters before stripping non-ASCII so `café` slugs to `cafe`, not the empty string.)
- **`SessionConfigKey.BranchNameHint` removed entirely.** It was no longer reachable from any production code, and removing the enum entry is the simplest way to keep future contributors from accidentally re-plumbing it.
- **Worktree creation timing unchanged.** `createSession` still only stores the provisional record; `_resolveSessionWorkingDirectory` still creates the worktree on first message. The only wiring change is that the prompt is now in scope when the branch name is computed.

## What went wrong or was misunderstood

- **First instinct was to fix the client-side plumbing gap, not to ask why the client knew the hint at all.** The initial fix dispatched `SessionConfigChanged` with `BranchNameHint` on the eager-create path. That worked, but the user pointed out the cleaner shape: since the worktree is materialized on first `sendMessage` (after `createSession`), the AH already has the prompt in hand and doesn't need the client to compute or transmit anything. **Prevented by:** doc body update on `copilot-agent-provider.md` (Session announcements section now spells out that the hint is server-derived from the prompt, and the eager-create path doesn't need to forward it) + new gotcha on the same doc (don't reintroduce client-side hint plumbing).
- **Possibly-undefined TS error in test slipped past local checks.** `getCopilotBranchNameHintFromMessage('a'.repeat(100)).length` — the helper returns `string | undefined`. Caught only by core-ci. **Prevented by:** existing memory ("Run `npm run compile-check-ts-native` for src/ TS-only checks"); just need to actually run it. No new doc entry needed.
- **Removing an exported helper without auditing concurrent main work risked merge conflicts.** `getAgentHostBranchNameHint` was deleted on this branch while `offsetToPosition` was added on `main`, both right next to each other in `agentHostSessionHandler.ts`. The conflict was trivial but a forcing function would have helped. **Prevented by:** nothing structural — a normal merge conflict, easy to resolve once flagged.

## What we learned

- The eager-create flow's clean separation between **provisional record** (created at folder-pick time) and **materialization** (deferred until first message) is exactly the seam that makes server-side derivation natural. `_materializeProvisional` already reads the *live* session config so anything dispatched between `createSession` and the first `sendMessage` is honored; adding the prompt as another input was a small, additive change.
- `String.prototype.normalize('NFKD')` is the right primitive for slug-style ASCII reduction: it decomposes accents to base letter + combining mark and folds compatibility chars (ligatures, fullwidth, superscripts, circled digits) so that the subsequent `[^a-z0-9]+` strip preserves the base letter instead of replacing the whole codepoint.

## Doc updates

- `docs/copilot-agent-provider.md`:
  - Session announcements section: added a paragraph documenting that the branch-name hint is derived server-side from the first prompt via `getCopilotBranchNameHintFromMessage`, plumbed through `_materializeProvisional(sessionId, prompt)`.
  - Added gotcha (2026-05-07): don't reintroduce client-side `branchNameHint` plumbing or a `SessionConfigKey.BranchNameHint`.
  - Changelog entry for `d116f50c33` / PR #315065.
