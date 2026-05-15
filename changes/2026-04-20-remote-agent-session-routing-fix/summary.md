# Align local & remote agent host sessionType IDs

**Date:** 2026-04-20
**VS Code branch:** roblou/agents/remote-agent-session-routing-fix
**VS Code SHA at finalize:** `5c0572d0cd` (post-merge HEAD of `origin/main`)
**PR:** [microsoft/vscode#311301](https://github.com/microsoft/vscode/pull/311301) — merged as `00f882a16c`.

## What was done

Fixed a bug where, with both a local agent host and a remote agent host enabled, starting a new session on the remote could silently route to the **local** host whenever a folder with the same path existed on both. The bug surfaced as: user picks the remote workspace entry (`project [host]`), types a message, sends — and the message lands in a still-active local untitled session.

The fix turned out to be structural rather than a one-line patch. The original investigation in `plan/2026-04-19-remote-agent-session-routing-fix/plan.md` proposed broadening a fallback in `SessionsManagementService.createNewSession` to silently substitute the provider's default session type when an unrecognized id arrived. We abandoned that plan once we realized the underlying issue was that local and remote providers exposed *different* session-type ids for the same agent (`agent-host-copilot` for local, `remote-<auth>-copilot` for remote), bridged through an alias map (`WELL_KNOWN_AGENT_SESSION_TYPES`). Deleting the alias map — and aligning the agent's id with what the UI calls it — was the cleaner fix.

Concretely:

1. **Renamed `CopilotAgent.id` from `'copilot'` to `'copilotcli'`.** The agent now advertises itself with the same name the UI shows. (`src/vs/platform/agentHost/node/copilot/copilotAgent.ts`.)
2. **Made `ISession.sessionType.id` = `agent.provider` directly.** Both `LocalAgentHostSessionsProvider` and `RemoteAgentHostSessionsProvider` now expose the same logical session-type id (`'copilotcli'`) for the Copilot agent, regardless of host. The cross-provider mismatch that caused the misrouting can no longer happen for the same agent.
3. **Collapsed all alias indirection.** Deleted `WELL_KNOWN_AGENT_SESSION_TYPES`, `DEFAULT_AGENT_HOST_PROVIDER`, `DEFAULT_AGENT_PROVIDER`, `wellKnownSessionType`, `wellKnownAgentProvider`, `_logicalSessionTypeForProvider`, `sessionTypeForProvider`, `agentProviderFromSessionType`, and the local provider's `_getSessionTypesFromContributions()` chat-sessions-registry fallback.
4. **Hoisted shared scaffolding to the base.** `_syncSessionTypesFromRootState` and `createAdapter` are now concrete on `BaseAgentHostSessionsProvider`. Subclasses contribute via a small `_adapterOptions()` hook (`description`, `buildWorkspace`) and `_formatSessionTypeLabel`. Replaced the `resourceSchemeForSessionType` + `agentProviderFromSessionType` pair with a single `resourceSchemeForProvider(provider)` hook.
5. **Removed silent fallbacks.** `protocolServerHandler.listSessions`, `remoteAgentHostProtocolClient.createSession`, `BaseAgentHostSessionsProvider.createAdapter` / `_getAgentProviderForSession`, and `AgentHostSessionAdapter`'s constructor now `throw` if the provider is missing instead of defaulting to `'copilot'`.
6. **Tightened `SessionsManagementService.createNewSession`.** Trivial cleanup: collapsed the `defaultType` → `sessionTypeId` two-step into one `?.id` chain, and addressed PR review by un-exporting the class.

The on-disk per-session DB key derives from the raw session id (`AgentSession.id(uri) = uri.path.substring(1)`), **not** the URI scheme, so the rename does not invalidate or migrate stored databases — old `copilot:///<sid>` URIs and new `copilotcli:///<sid>` URIs hit the same DB row.

## Key decisions

- **Rename the agent rather than alias it.** We considered keeping `CopilotAgent.id = 'copilot'` and bridging it to `'copilotcli'` via an alias map. We chose the rename. Aliases are state that has to be maintained in lockstep across the protocol layer, the providers, and any UI that compares ids; they are a refactor accident waiting to happen, and the migration cost was zero (DB keys are scheme-independent).
- **Reject the original "broaden the fallback" plan.** Falling back to the provider's first session type whenever an unrecognized id arrived would have papered over the real bug: the same agent should not have different ids on different hosts. Silent fallbacks were how the bug existed in the first place.
- **Throw on missing provider, do not default.** Every silent `?? 'copilot'` fallback was either dead (because the provider always set it) or load-bearing for a bug. We removed all of them in favor of `throw`s.
- **Don't allow-list agent provider names.** `_syncSessionTypesFromRootState` now accepts whatever `rootState.agents[].provider` the AH advertises, verbatim. There is no enum, no validation, no map. If a future agent host advertises a new agent, it appears in the picker with no code change.

## What went wrong or was misunderstood

- **Initial diagnosis pointed at the wrong fix.** The `plan.md` proposed broadening a fallback in `SessionsManagementService.createNewSession`. That would have hidden the bug, not fixed it. The real bug was an alias-map indirection one layer down. — **prevented by:** new gotcha on `agent-host-sessions-providers.md` against reintroducing alias maps; new "Session-type id vs. resource scheme" doc section explaining why the two concepts must stay separate; this summary.
- **Multiple "well-known" alias layers were dead code.** `WELL_KNOWN_AGENT_SESSION_TYPES`, `_logicalSessionTypeForProvider`, `wellKnownSessionType`/`wellKnownAgentProvider`, `_getSessionTypesFromContributions` all only existed to bridge `'copilot'` (the agent id) ↔ `'copilotcli'` (the UI id) and looked load-bearing on first read. Time was spent understanding them before realizing they could simply be deleted by renaming the agent. — **prevented by:** new gotcha on `copilot-agent-provider.md` ("don't reintroduce a `'copilot' → 'copilotcli'` mapping anywhere") + the cross-cutting principle that one entity should have one name.
- **Silent `?? 'copilot'` fallbacks hid the original bug.** When the client sent the wrong scheme, the server's `provider: AgentSession.provider(s.session) ?? 'copilot'` happily wrote `'copilot'` into the metadata. The misrouting then appeared as a "natural" outcome, not a bug. — **prevented by:** new gotcha on `agent-host-sessions-providers.md` enumerating the four sites that now `throw` on missing provider, with the rule "failing loud is the contract."
- **CI test failure was misclassified mid-session as pre-existing/unrelated.** Three `copilotAgent.test.ts` failures were flagged as "not caused by my changes." That was wrong — they all asserted against the old `'copilot'` scheme. The literal `'copilot'` in `AgentSession.uri('copilot', ...)` is a `string` parameter, so TypeScript didn't catch it. Lesson: when CI fails after a rename, the default assumption should be that the rename caused it, even if specific assertions look unrelated. — **prevented by:** new gotcha on `copilot-agent-provider.md` ("when renaming `CopilotAgent.id`, audit hardcoded literals in tests under `src/vs/platform/agentHost/test/node/`").
- **Husky hygiene quirk: empty `import type {} from ...` triggers "File not formatted".** When the last symbol was removed from a `state.js` import, the empty import remained and broke the pre-commit hook. — Not worth a doc gotcha on its own (one-off), but noted here.
- **Diagnostic logs were left in code at PR-review time.** Two `logService.info` calls (containing workspace URIs) were added during debugging and forgotten. Reviewer caught both. — Not worth a gotcha; the broader principle ("don't log user paths at info level") is already common code hygiene.

## What we learned

- The cleanest fix to a routing bug is often "make the keys match" rather than "add a fallback when they don't." Silent fallbacks are a reliability-flavored anti-pattern: they convert "this thing is broken" into "this thing works in the wrong way."
- For protocol-driven UIs, the "what does the picker show" data should come from exactly one source (the protocol's root state). Multi-source fallbacks (e.g. the chat-sessions registry as a backup) sound robust but lock you into maintaining the cross-source mapping forever.
- DB key independence from URI scheme is a pleasant accident here — `AgentSession.id(uri) = uri.path.substring(1)` makes the rename a no-op for stored data. Worth knowing for any future agent-id rename.

## Doc updates

- **`docs/agent-host-sessions-providers.md`**: added new section "Session-type id vs. resource scheme"; rewrote the "Base / subclass split" hooks list (`resourceSchemeForProvider`, `_adapterOptions`, `_formatSessionTypeLabel`; `_syncSessionTypesFromRootState` and `createAdapter` now concrete on base); added two gotchas (no alias-map indirection; no silent provider fallbacks) plus one for `_getAgentProviderForSession` throwing.
- **`docs/copilot-agent-provider.md`**: updated `AgentSession.uri('copilot', ...)` → `'copilotcli'`; added a callout that `CopilotAgent.id` is now `'copilotcli'` and that the rename is DB-safe; added three gotchas (don't reintroduce alias maps; don't restore the `?? 'copilot'` fallback; audit test files when renaming an agent id).
- **`docs/agent-host-topology.md`**: updated `provider:` example value from `'copilot'` to `'copilotcli'`; updated `sessionType` example values; clarified that the chat-sessions-registry `sessionType` is distinct from the Sessions-app `ISession.sessionType` (cross-link to the new section in agent-host-sessions-providers).
- **`docs/agent-host-session-handler.md`**: updated `provider:` example value in the `IAgentHostSessionHandlerConfig` snippet.
- No new docs created.
- No `## Active debt & gotchas` cross-cutting entries added — the new gotchas are scoped to specific docs.
