# Use server-backed archived state for agent host sessions

**Date:** 2026-07-10
**VS Code branch:** roblou/agenthost-archived-server-state
**VS Code SHA at finalize:** f84dd062b5
**PR:** [#325399](https://github.com/microsoft/vscode/pull/325399) (issue [#325398](https://github.com/microsoft/vscode/issues/325398))

## What was done

An errored+archived agent-host session (status `66` = `Error | IsArchived`) was showing up in the non-archived date sections of the editor-window chat sessions viewer instead of the Archived section. Root cause: `AgentSessionsModel.isArchived()` (`src/vs/workbench/contrib/chat/browser/agentSessions/agentSessionsModel.ts`) merged the server-provided `session.archived` with a per-resource local view-state overlay and gave the **local** overlay precedence — `resolveStateEntry(session)?.archived ?? Boolean(session.archived)`. Because `??` only falls through on null/undefined, a persisted local `archived: false` (e.g. from a prior local unarchive) permanently masked the server's `archived: true`.

The fix special-cases agent-host targets: when `isAgentHostTarget(session.providerType)` is true, `isArchived()` returns `Boolean(session.archived)` and ignores the local overlay. Non-agent-host providers keep the existing overlay behavior. The section grouping (`groupAgentSessionsByDate` / `groupSessionsCapped` / `groupSessionsByRepository`) keys entirely off `isArchived()`, so this single merge decides placement.

## Key decisions

- **Scope the change to agent-host targets only**, not all providers. Archived state is server-authoritative only for agent host (`SessionStatus.IsArchived`); other providers (Cloud, extension-host CLI, local) still rely on the client-side overlay, so the generic merge stays for them.
- **Use `isAgentHostTarget(providerType)`** (already imported in the model) as the discriminator — it covers both local `agent-host-*` and remote `remote-*` hosts, not just the static enum values.
- **Did not** wire the editor-window Archive/Unarchive actions to the server in this change — flagged as follow-up debt (see below) rather than expanding scope.

## What went wrong or was misunderstood

- **Initial hypothesis blamed the wrong line.** The reported suspect was the bitmask expression `(status & IsArchived) === IsArchived` in `agentHostSessionListController._makeItem`, on the theory that a combined status (66) wouldn't be detected as archived. That expression is actually correct: for a **single-bit** flag, `& FLAG === FLAG` is equivalent to `& FLAG !== 0`; the `=== FLAG` form only differs from `!== 0` for **composite** flags like `InputNeeded = (1<<3)|(1<<4)`. The real bug was two layers downstream in the model's merge. — **prevented by:** the bitmask note now in the new `gotcha:` on [agent-host-session-handler](../../docs/agent-host-session-handler.md) (and this summary).
- **The archived flow crosses an undocumented component.** The editor-window session list model (`agentSessionsModel.ts`, ~1045 lines: the local archived/pinned/read overlay, serialization, and date/capped/repo sectioning) had **no** knowledge doc, so the overlay-vs-server-truth interaction had to be reverse-engineered from code. — **prevented by:** new `gotcha:` on the session-handler doc (which already covers the `agentHostSessionListController` producer of the `archived` field), documenting the server-authoritative contract and pointing at `agentSessionsModel.isArchived`.
- **Two surfaces archive differently, and only one reaches the server.** The agent-window provider (`baseAgentHostSessionsProvider.archiveSession`) dispatches `SessionIsArchivedChanged` to the host; the editor-window viewer's Archive/Unarchive actions (`agentSessionsActions` → `session.setArchived`) only write the local overlay — `IChatSessionItemController` has no archive method. This inconsistency wasn't obvious until tracing both paths, and the fix turns the editor-window buttons into display no-ops for agent-host sessions. — **prevented by:** new `debt:` on the session-handler doc plus a cross-cutting pointer in `index.md`.

## What we learned

- Archived is server-owned for agent host at multiple layers: the `IsArchived` status bit (protocol), `AH_META_IS_ARCHIVED_DB_KEY` written by `AgentSideEffects` on `SessionIsArchivedChanged` (orchestrator), and the derived read-only chat interactivity (`effectiveChatInteractivity`). The editor-window viewer's local overlay was the one place still treating archived as client-owned for these sessions — a direct instance of the "put truth at the layer that owns it" design principle.

## Doc updates

- **docs/agent-host-session-handler.md** — added one `gotcha:` (agent-host archived is server-authoritative; `isArchived()` must ignore the local overlay for agent-host targets; includes the single-bit-vs-composite bitmask note) and one `debt:` (editor-window Archive/Unarchive actions never dispatch to the host). Added a 2026-07-10 changelog entry (SHA `f84dd062b5`).
- **index.md** — added a cross-cutting `gotcha/debt` pointer under `## Active debt & gotchas` for the editor-window-overlay-vs-agent-window-server-dispatch inconsistency.
