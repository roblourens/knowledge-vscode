# Plan: Recover from Copilot SDK auth failures without killing the agent host

When the Copilot SDK's internal token exchange goes stale (typical symptom: `"Authorization error, you may need to run /login"` mid-session), the agent host today has no signal back to the renderer, no way to reset the SDK client, and no way to push a freshly resolved GitHub OAuth token through to the SDK while sessions are alive. The only fix today is killing the agent host process. This plan closes those three gaps so recovery is automatic when a fresh token can be resolved silently, and falls back cleanly to the existing interactive prompt when it can't.

## Knowledge context used

- [copilot-agent-provider](../../docs/copilot-agent-provider.md) — `Authentication contract` section (`_ensureClient` throws `AHP_AUTH_REQUIRED`; renderer-side `authenticationPending` autorun retries) and the gotcha that `_refreshModels` swallows all throws.
- [agent-host-protocol](../../docs/agent-host-protocol.md) — `AHP_AUTH_REQUIRED` (-32007) is the contract for "this command needs auth"; consumers expect a throw, not an empty result.
- [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md) — one-shot `_ensureSessionCache` is auth-aware via `authenticationPending`; the same hook is what we want to reuse on a mid-session re-auth.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md) — `SessionError` action is already plumbed through `_emitAction` in `CopilotAgentSession`; the renderer side is what surfaces "auth retries" today.

## Approach

There are three separate but related fixes. We treat them as one feature because the recovery story only works end-to-end when all three land — `(1)` gives the agent host a signal to act on, `(2)` resets state on both sides so the next push actually reaches the SDK, and `(3)` removes the `_sessions.size === 0` gate that silently no-ops mid-session token rotation.

**Detection (1).** `CopilotAgentSession` already subscribes to the SDK's `session.error` event and forwards every error to the renderer as a `SessionError` action ([copilotAgentSession.ts:1607-1619](../../../../vscode/src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts#L1607-L1619)). The SDK's `ErrorData` has a structured `errorType: "authentication" | "authorization" | …` field plus an optional `statusCode` ([session-events.d.ts:336-360](../../../../vscode/node_modules/@github/copilot-sdk/dist/generated/session-events.d.ts#L336-L360)) — no string matching needed. We add a small predicate `isSdkAuthError(data)` that returns true for `errorType === 'authentication' | 'authorization'` or `statusCode === 401`. When it fires, the session calls a new callback on its owning `CopilotAgent` (e.g. `onSdkAuthFailure(): void`) before continuing to emit the `SessionError` action — the renderer still gets the error, but the agent also gets the kick.

**Reset on the agent host (2).** `CopilotAgent.onSdkAuthFailure` clears `_githubToken` and calls `_stopClient()`. Clearing the token is the key piece: it means the next `_ensureClient()` call (on the user's next `sendMessage`) throws `ProtocolError(AHP_AUTH_REQUIRED, …)`, which the renderer-side session handler already maps into the existing `resolveAuthenticationInteractively` flow. If the user's GitHub OAuth token is still valid, that resolver finds it silently and re-pushes via `authenticate()`. If it's truly gone, the user gets prompted. This is exactly the contract the bootstrap path already obeys, just reused for mid-session recovery. We do **not** auto-retry the failing turn — per alignment, the user resends.

**Reset on the renderer (2, cont.).** The renderer's `AgentHostAuthTokenCache` would otherwise dedupe a re-push of the same token even after we've cleared the SDK side. We need the cache to drop the stale entry whenever a re-auth is triggered for a remote agent host. The cleanest hook: when the connection's session handler maps an `AHP_AUTH_REQUIRED` reply into `resolveAuthenticationInteractively`, we already have the connection's `authTokenCache` in scope — clear the resource entry first so the resolved token always re-pushes. This already happens on RPC failure ([agentHostAuth.ts:151-154](../../../../vscode/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostAuth.ts#L151-L154)) but not on the "successful authenticate, but the SDK later rejected the token" path; we extend it.

**Mid-session token rotation (3).** Today `authenticate()` only restarts the SDK client if there are zero active sessions ([copilotAgent.ts:318](../../../../vscode/src/vs/platform/agentHost/node/copilot/copilotAgent.ts#L318)). That's the wrong gate: a token rotation while sessions are live silently fails to propagate to the SDK. We drop the `_sessions.size === 0` condition and always restart the client when `tokenChanged && this._client`. The cost is an in-flight turn dies with an SDK error — but that's strictly better than continuing with a token the SDK doesn't know about. The session sequencer plus the existing `_clientStarting` reuse means concurrent `sendMessage` calls naturally re-build the client once. We log the restart prominently.

Phases run in order; (1) is a pure addition, (3) is a one-line behavior change, (2) ties them together.

## Phases

### Phase A — Detection seam in `CopilotAgentSession` and `CopilotAgent`
- Add a new module-private helper `isSdkAuthError(data: ErrorData): boolean` co-located with the session error mapping (e.g. in `copilotAgentSession.ts` near the `onSessionError` handler). Predicate: `data.errorType === 'authentication' || data.errorType === 'authorization' || data.statusCode === 401`.
- Plumb a new `onSdkAuthFailure?: () => void` callback into the `CopilotAgentSession` constructor options and store it. Existing call site in `CopilotAgent` wires it to a new `_handleSdkAuthFailure(sessionId: string)` method on the agent.
- In the `wrapper.onSessionError` handler, call the callback **before** emitting `SessionError` so the agent's reset is in flight before the renderer sees the error and picks a recovery path. The `SessionError` action still fires unchanged.
- New unit tests under [copilotAgentSession.test.ts](../../../../vscode/src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts) covering: (a) auth-typed `session.error` triggers the callback exactly once and still emits `SessionError`; (b) non-auth `session.error` does not trigger the callback.

### Phase B — Agent-side reset
- Implement `CopilotAgent._handleSdkAuthFailure(sessionId)`: log at `info`, clear `_githubToken`, and `await this._stopClient()`. Sequence through `_sessionSequencer.queue(sessionId, …)` to avoid racing in-flight session work — same pattern as archive cleanup. Idempotent: if `_githubToken` is already undefined or `_client` is already gone, this is a no-op.
- Optional: emit a single `_logService.warn` line so it's easy to grep `[Copilot] SDK auth failure; resetting client` in the agent host logs.
- Unit test in [copilotAgent.test.ts](../../../../vscode/src/vs/platform/agentHost/test/node/copilotAgent.test.ts): given a started client and a stored token, invoking `_handleSdkAuthFailure` clears the token, stops the client, and a subsequent operation that goes through `_ensureClient()` throws `AHP_AUTH_REQUIRED`.

### Phase C — Drop the `_sessions.size === 0` gate in `authenticate()`
- Change [copilotAgent.ts:318](../../../../vscode/src/vs/platform/agentHost/node/copilot/copilotAgent.ts#L318) from `if (tokenChanged && this._client && this._sessions.size === 0)` to `if (tokenChanged && this._client)`.
- Update / add test in [copilotAgent.test.ts](../../../../vscode/src/vs/platform/agentHost/test/node/copilotAgent.test.ts): when `authenticate()` receives a new token while a session is open, the SDK client is restarted (via the existing `_createCopilotClient` factory seam).
- The existing comment near that branch (if any) should be replaced with a short note: "Restart the SDK client whenever the token changes; the SDK has no API to push a fresh `gitHubToken` into a running client, so a restart is the only way the new token reaches it. In-flight turns will surface an SDK error and the user resends."

### Phase D — Renderer-side cache invalidation on interactive re-auth
- In [agentHostAuth.ts](../../../../vscode/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostAuth.ts) `resolveAuthenticationInteractively`, before resolving the token, call `options.authTokenCache?.clear(resource.resource)` for the resource being re-authenticated. This guarantees that even if the resolver ends up returning the same token bytes as last time, the subsequent `authenticate()` RPC is **not** suppressed — the agent host needs the push to re-seed `_githubToken` after our reset cleared it.
- Add coverage to [agentHostAuth.test.ts](../../../../vscode/src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostAuth.test.ts) for: (a) cache cleared before resolving, (b) same-token re-push not deduped on the interactive path.

### Phase E — End-to-end smoke (manual)
- Local agent host: open a session, send a message, then run `kill -USR1` / equivalent to simulate token invalidation (or test seam: expose a `_test_simulateSdkAuthFailure` method on `CopilotAgent` gated by an env var, or just trigger via the unit tests).
- Verify in `agent-host.log` that the sequence is: `Session error: authentication - …` → `[Copilot] SDK auth failure; resetting client` → renderer side `Authenticating for resource: https://api.github.com` → next `sendMessage` succeeds.
- Remote SSH agent host: same flow over the SSH transport; verify the renderer cache invalidation actually causes the `authenticate` RPC to re-fire.

## Relevant files

- `src/vs/platform/agentHost/node/copilot/copilotAgent.ts` — `authenticate()` (drop the size gate), new `_handleSdkAuthFailure()`, wire callback into session construction.
- `src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` — `onSessionError` handler: add `isSdkAuthError` predicate and call new callback.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostAuth.ts` — `resolveAuthenticationInteractively`: clear cache for the resource before re-resolving.
- `src/vs/platform/agentHost/test/node/copilotAgent.test.ts` — tests for `_handleSdkAuthFailure` + dropped size gate.
- `src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts` — tests for the auth-error predicate and callback wiring.
- `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostAuth.test.ts` — tests for the interactive re-auth cache clear.

## Verification

1. `npm run test-node -- --grep "CopilotAgent"` — covers the new agent-side reset and `authenticate` behavior change.
2. `npm run test-node -- --grep "CopilotAgentSession"` — covers the predicate and callback plumbing.
3. `scripts/test.sh --grep "agentHostAuth"` — covers the renderer-side cache invalidation.
4. Manual SSH agent host smoke per Phase E. The reproduction from this session is the canonical scenario.
5. Real-SDK integration test [`toolApprovalRealSdk.integrationTest.ts`](../../../../vscode/src/vs/platform/agentHost/test/node/protocol/toolApprovalRealSdk.integrationTest.ts) should still pass under `AGENT_HOST_REAL_SDK=1` — we're not changing the happy path.

## Decisions

- **Reuse `AHP_AUTH_REQUIRED`, don't invent a new error code.** The renderer already knows how to react: throw `AHP_AUTH_REQUIRED` → `resolveAuthenticationInteractively` → push token. Adding a new "soft re-auth" channel would duplicate machinery for no behavioral gain.
- **Auto-recover silently when a fresh token is available; prompt only when it isn't.** Per alignment. Users shouldn't see modal dialogs for what is functionally a token refresh — they only see one when actual user action is required.
- **No auto-retry of the failing turn.** Per alignment. Auto-retry adds nontrivial state (which messages are retried, which side owns retry, what about partial tool calls?) for marginal UX gain. The user resends.
- **Drop the `_sessions.size === 0` gate unconditionally.** A token change that doesn't reach the SDK is a latent bug regardless of session count. The cost of restarting the client mid-session (one in-flight turn dies with an SDK error) is acceptable because (a) it's rare — tokens don't rotate often — and (b) the alternative is the SDK using a stale token forever. This is strictly better.
- **Don't try to detect "stale internal Copilot bearer token vs. expired GitHub OAuth token".** The agent host doesn't have visibility into the SDK's internal token. Treating any auth-typed `session.error` as "reset the client and let the renderer try again" is the right shape.
- **Out of scope:** retry-with-backoff inside the agent host; surfacing an SDK auth-error toast directly from the agent host (the renderer's existing error rendering is fine); changes to `_refreshModels`'s blanket-catch behavior (separate gotcha — leave for a focused fix).

## Risks and open questions

- **What if the SDK emits an auth-typed `session.error` that is *not* token-related?** (E.g. an entitlement check failed.) Resetting the client and re-pushing the same token would still fail the same way, so the user would see two error events — once from the SDK, then `AHP_AUTH_REQUIRED` and a re-resolve, then another error on the next send. Acceptable: the second pass shows the same problem more clearly.
- **What about the in-flight turn the user just sent?** It dies with an SDK error message. The user re-sends. This is the explicit alignment outcome.
- **Risk of restart loop:** if every `sendMessage` triggers a `session.error` that triggers a reset, we'd reset on every turn. Mitigation: the reset is idempotent and the renderer-side resolver only re-pushes on `onDidChangeSessions` or a `AHP_AUTH_REQUIRED` throw; if the same token keeps failing, the user gets a normal error and stops sending. We should add a tiny debounce only if Phase E surfaces noise — not in v1.

## Docs that will need updating

- `docs/copilot-agent-provider.md` — extend the `Authentication contract` section with the mid-session reset path and a new gotcha that `authenticate()` no longer gates on `_sessions.size`. Add a note that `_handleSdkAuthFailure` clears `_githubToken` and stops the client so `_ensureClient` re-throws `AHP_AUTH_REQUIRED`.
- `docs/agent-host-session-handler.md` (if relevant prose exists about mid-turn auth retries) — confirm the existing `authenticationPending` retry path now also triggers off mid-session SDK auth failures, not just startup.
- (No new doc — this is an extension of an existing component.)
