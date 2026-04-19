# Surface worktree-created announcement in agent host Copilot CLI sessions

**Date:** 2026-04-19
**VS Code branch:** agents/copilot-cli-progress-message-update
**VS Code SHA at finalize:** adc4f6e17e
**PR:** https://github.com/microsoft/vscode/pull/311254

## What was done

When a Copilot CLI session is configured with `isolation: 'worktree'`, the agent host now emits a "Created isolated worktree for branch `X`" markdown announcement at the top of the session's first response — both live as the model is replying for the first time, and on every subsequent reopen of the session. This brings parity with the existing extension-host Copilot CLI worktree experience.

The implementation lives entirely in `src/vs/platform/agentHost/node/copilot/copilotAgent.ts`. It uses two independent paths:

- **Live path:** `_resolveSessionWorkingDirectory` writes the rendered markdown into an in-memory `_pendingFirstTurnAnnouncements: Map<sessionId, string>`. The first call to `sendMessage` for that session drains the entry one-shot and fires a synthetic `IAgentDeltaEvent` (`messageId = 'copilot-announcement-<uuid>'`) before delegating to the SDK. The mapper appends the SDK's subsequent deltas to the same markdown part, so the announcement and the model's reply render as one continuous block.
- **Restore path:** the branch name is also persisted as `copilot.worktree.branchName` in the session DB. `getSessionMessages` reads it via `tryOpenDatabase()` and, using a local `prependAnnouncementToFirstAssistantMessage` helper, prepends the announcement to the first **top-level** assistant message in the returned message list (skipping any with `parentToolCallId` so it doesn't get buried inside a subagent).

Test coverage is two real end-to-end tests in `copilotAgent.test.ts`, built around a `TestableCopilotAgent` subclass that overrides `_resumeSession` to splice in a fake `IFakeAgentSession`. The tests actually exercise `sendMessage` + `getSessionMessages` against a real in-memory `SessionDatabase`, rather than verifying the helper's string concatenation in isolation.

## Key decisions

- **No new event type.** The first attempt invented an `IAgentResponsePartEvent`. The user pointed out: it's just markdown — render it through the existing delta channel. The protocol stays unchanged; the announcement is indistinguishable from any other assistant text on the wire.
- **Two independent paths, same markdown.** The live path can't read from history (the assistant message doesn't exist yet), and the restore path can't observe the live emission across processes. Splitting them keeps each one trivial. They both go through `buildWorktreeAnnouncementText(branchName)` for a single source of truth.
- **In-memory live path, not DB-backed.** A second iteration tried to make the live path survive process restarts using a `copilot.worktree.announcementEmitted` DB flag. The user called this overkill: the only edge it covered was "agent restarts between worktree creation and the very first user prompt", and losing the announcement in that narrow window is acceptable. Once any reply exists, the restore path keeps it durable across reopens, which is what actually matters. Reverted to the simple in-memory map.
- **Restore path lands on the first *top-level* assistant message.** `prependAnnouncementToFirstAssistantMessage` filters out messages with `parentToolCallId` so the announcement always shows up on the parent turn, not buried inside a subagent's tool history.
- **Real e2e tests, not concatenation tests.** The user explicitly rejected the first round of tests for being "dumb" — they only verified that the helper concatenated strings. The replacement creates a session with a worktree config, sends a message, and asserts the delta event fires (live), then re-resolves messages and asserts the prepend (restore).

## What went wrong or was misunderstood

- **Initial design invented a new `IAgentResponsePartEvent`.** Believed an announcement needed a distinct event so the UI could render it differently. It doesn't — it's just markdown content into the same response part. **Prevented by:** new "Session announcements (worktree creation)" section on `copilot-agent-provider`, which says explicitly to use the existing delta channel for this kind of thing.
- **Second iteration over-engineered restart resilience.** Added a `copilot.worktree.announcementEmitted` DB flag and async helpers to make the live path survive process restarts. The narrow "restart between worktree creation and first prompt" window isn't worth the complexity. **Prevented by:** explicit `gotcha` on `copilot-agent-provider` saying the live path is intentionally in-process only and not to add a DB flag back, plus the rationale in this summary.
- **First test attempt verified string concatenation, not behaviour.** Wrote tests against the helper functions in isolation. They passed but proved nothing about the user-facing flow. **Prevented by:** expanded "Testing Pattern" section on `copilot-agent-provider` describing `TestableCopilotAgent` + `IFakeAgentSession` as the seam for real e2e tests against a fake session.
- **`IAgentDeltaEvent` field is `content`, not `delta`.** Name of the event made `delta` look right at a glance — even the Copilot reviewer's auto-suggestions had it wrong. **Prevented by:** `gotcha` on `copilot-agent-provider` calling out the field name explicitly.
- **Initial restore-path prepend treated all assistant messages equally.** Almost shipped a version that would land the announcement on a subagent's inner message if one happened to come first. The fix is the `!m.parentToolCallId` filter. **Prevented by:** `gotcha` on `copilot-agent-provider` describing the top-level filter and why it matters.
- **Hygiene mistakes in the new test file.** Tried to `import 'path'` (blocked by lint) and used `as unknown as T` to satisfy a generic helper signature (blocked by `local/code-no-dangerous-type-assertions`). Both produced one wasted compile-check round-trip each. Also tried to run tests via `scripts/test.sh` (Electron, crashes outside an interactive session) before falling back to `npm run test-node`. **Prevented by:** `gotcha` and updated "Testing Pattern" section on `copilot-agent-provider` listing all three rules.

## What we learned

- The "live + restore" pattern is generalizable. Any one-shot session-scoped announcement that wants to show up live during the first turn *and* on every subsequent reopen needs an in-memory queue keyed by session ID (drained in `sendMessage`) plus a persisted breadcrumb (read in `getSessionMessages`). They're independent paths sharing the same render function. If a second consumer wants this (e.g. "restored from snapshot", "config migrated"), refactor into a small helper.
- `_resumeSession` and `_resolveSessionWorkingDirectory` being `protected` is now a contract for tests, not just an accidental visibility. Worth preserving on future refactors.
- The session-handler mapper appending SDK deltas onto a synthetic announcement message works because the SDK's own delta `messageId` differs from the synthetic one — so the mapper closes out the announcement part and starts a fresh one for the SDK's reply, but they render visually contiguous because both are markdown into the same response. Don't try to cheat by reusing the SDK's `messageId` for the synthetic event; the mapper's grouping is what makes this look right.

## Doc updates

- `docs/copilot-agent-provider.md`:
  - Added "Session announcements (worktree creation)" section describing the live + restore split, the synthetic `IAgentDeltaEvent`, the `copilot.worktree.branchName` metadata key, and the top-level-assistant-message filter on the restore path.
  - Added `copilot.worktree.branchName` to the metadata key list with a back-link to the new section.
  - Expanded "Testing Pattern" with `TestableCopilotAgent` / `IFakeAgentSession` as the e2e seam, the two `test/node/` hygiene rules (no `'path'` import, no `as unknown as T`), and the `npm run test-node` instruction.
  - Added gotchas: subagent-skip in the restore prepend, deliberately-non-persistent live path (don't reintroduce the DB flag), `IAgentDeltaEvent.content` field name, test-file lint rules.
  - Changelog entry for `adc4f6e17e`.
