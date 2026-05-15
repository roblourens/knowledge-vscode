# Tasks: Recover from Copilot SDK auth failures without killing the agent host

1. [x] Add `isSdkAuthError(data)` predicate and `onSdkAuthFailure` callback option to `CopilotAgentSession`; call it from the existing `wrapper.onSessionError` handler in `src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` before emitting the `SessionError` action.
2. [x] Add `CopilotAgent._handleSdkAuthFailure(sessionId)` in `src/vs/platform/agentHost/node/copilot/copilotAgent.ts`: sequenced through `_sessionSequencer`, clears `_githubToken`, calls `_stopClient()`. Wire it as the `onSdkAuthFailure` callback at session construction.
   - note: marked `protected` (not `private`) so the test subclass can expose it.
3. [x] In `src/vs/platform/agentHost/node/copilot/copilotAgent.ts`, change the `authenticate()` restart guard from `if (tokenChanged && this._client && this._sessions.size === 0)` to `if (tokenChanged && this._client)`. Update the surrounding comment.
4. [x] In `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostAuth.ts`, in `resolveAuthenticationInteractively`, call `options.authTokenCache?.clear(resource.resource)` before resolving the token for that resource.
5. [x] Tests: extended `copilotAgentSession.test.ts` with cases for auth-typed / authorization-typed / 401-status errors firing the callback and non-auth errors not firing it; all still emit `SessionError`.
6. [x] Tests: extended `copilotAgent.test.ts` with `_handleSdkAuthFailure` clears token + makes subsequent ops throw `AHP_AUTH_REQUIRED`, and `authenticate()` with a new token while a stub session is registered triggers `_createCopilotClient` again.
   - note: changed `_sessions` from `private` to `protected` so the test subclass can inject a stub session entry.
7. [x] Tests: extended `agentHostAuth.test.ts` with a case that a same-token re-push is not deduped on the interactive path (proves the cache is cleared before resolving).
8. [ ] Manual smoke (Phase E): local + remote SSH agent host. Verify the log sequence and that the user's next `sendMessage` succeeds without killing the agent host process.

## Discoveries for finalize

- gotcha: `src/vs/platform/agentHost/node/copilot/copilotAgent.ts:authenticate` — restart now happens unconditionally on token change. Anyone reintroducing a "skip restart while sessions are open" optimization will silently break mid-session token rotation; the SDK has no API to push `gitHubToken` into a running client.
- gotcha: `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostAuth.ts:resolveAuthenticationInteractively` — clearing the per-resource cache entry before resolving is load-bearing. After an SDK auth failure resets the agent host's `_githubToken`, the renderer-side cache still holds the previous token bytes; without the clear, the dedupe in `authenticateProtectedResources` (or any future caller that consults the cache before calling `authenticate`) would suppress the re-push.
