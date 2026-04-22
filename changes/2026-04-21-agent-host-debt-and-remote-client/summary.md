# Agent Host debt audit and remote protocol client lifecycle cleanup

**Date:** 2026-04-21
**VS Code branch:** roblou/remote-agent-host-protocol-client-lifecycle
**VS Code SHA at finalize:** b1564bc1e1
**PR:** https://github.com/microsoft/vscode/pull/311814

## What was done

Audited the VS Code Agent Host implementation, the sibling `agent-host-protocol` repo, and the client-side VS Code integrations for tech debt and test coverage gaps. The audit used explicit lenses first: debt markers, unsafe casts, suspicious async/lifecycle patterns, architecture seams, protocol drift, and test confidence.

Then implemented the first cleanup area: `RemoteAgentHostProtocolClient` request lifecycle. The draft PR rejects pending and later JSON-RPC requests on close/dispose, preserves structured JSON-RPC errors through `RemoteAgentHostProtocolError`, races explicit transport `connect()` against close/dispose, types the VS Code-only `shutdown` request path, and adds focused browser-unit coverage. Copilot review found one additional disposal-order issue; it was fixed locally by overriding `dispose()` to close before `super.dispose()` and by tightening the connect-dispose regression test so it rejects without completing the fake transport's connect promise.

## Key decisions

- Started with the remote protocol client rather than reducer purity. This area is high-impact because it is the remote `IAgentConnection` boundary, Rob had edited nearby code before, and blame showed it was not Connor-only.
- Kept full reconnect/replay out of the first PR. Correct close/dispose/request settlement was a smaller prerequisite that could be tested deterministically.
- Added `RemoteAgentHostProtocolError` instead of throwing plain `Error` so callers/tests can inspect JSON-RPC `code` and `data` without string matching.
- Kept `shutdown` as a typed VS Code extension method, not a generated AHP command, because the current wire method is VS Code-specific. If it becomes public protocol, move it to `agent-host-protocol` first.
- Did not chase generic coverage percentage. The useful coverage was targeted lifecycle coverage for the previously untested remote client.
- Did not push the Copilot review fix yet from this knowledge-finalize step. The source tree has the local fix and the focused test passes; decide separately whether to amend/push a PR update.

## What went wrong or was misunderstood

- Assumed a constructor-registered `toDisposable(...)` could reliably fire `onDidClose` during `dispose()` - false because `Disposable` disposes registered children in insertion order, and field-initialized emitters are registered before constructor disposables. **Prevented by:** gotcha in [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md#disposal-ordering).
- Initial lifecycle tests let `connect()` reject on dispose only after the fake transport's deferred connect was manually completed. That missed the real bug: callers need prompt rejection even if transport connect never resolves. **Prevented by:** tightened `remoteAgentHostProtocolClient.test.ts` coverage and the testing notes in [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md#tests).
- The audit first treated `remoteAgentHostProtocolClient.ts` and `webSocketClientTransport.ts` as coverage targets, but neither appeared in the detailed coverage output because they had no direct tests. **Prevented by:** coverage gap notes in this summary and the new remote protocol client doc.
- The remote client `shutdown` path looked like ordinary protocol traffic but actually bypassed the generated `ICommandMap`. The old implementation cast a request as a response-shaped type. **Prevented by:** extension-request section in [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md#extension-request-path).
- Finalize initially tried to fast-forward the knowledge worktree while local doc edits were present and `origin/main` had moved. The safe path was to preserve edits, fast-forward, then manually resolve doc conflicts. **Prevented by:** this summary; the finalize skill already says to stop on a failed ff-only merge.

## What was accomplished so another agent does not duplicate it

Do not reopen these as fresh debt tasks unless the PR changes again:

- `RemoteAgentHostProtocolClient` now has focused unit tests covering success, structured error responses, unknown response ids, close rejection, dispose rejection, disposal ordering when the transport also closes, late responses after close, post-close/post-dispose request attempts, connect close/dispose races, and `shutdown` request/error behavior.
- Pending JSON-RPC requests no longer hang silently across transport close or client dispose.
- Requests attempted after close/dispose reject immediately and do not send messages.
- JSON-RPC error responses preserve `code` and `data` via `RemoteAgentHostProtocolError`.
- The VS Code-only `shutdown` extension method now sends an `IJsonRpcRequest` shape instead of using a response-shaped cast.
- The Copilot review disposal bug has a local fix and a regression test: dispose now closes before `super.dispose()`, and connect disposal rejection no longer depends on completing the fake transport promise.

## Remaining debt tasks from the audit

1. Protocol reducers still stamp `Date.now()` inside reducer branches. Move timestamps into action payloads or reducer context, then add reducer and optimistic replay tests proving deterministic `modifiedAt`.
2. Remote reconnect still mostly bypasses AHP replay/snapshot semantics. Add stable client ids/subscriptions, real `reconnect`, replay/snapshot fallback, and optimistic reconciliation tests.
3. Server reconnect replay eligibility appears off by one. Define the invariant and test `lastSeen = oldest - 1` as replayable while older gaps snapshot.
4. Server reconnect does not re-register reverse filesystem authority. Factor initialize/reconnect client setup and test reverse `resourceRead`/`resourceWrite` after reconnect.
5. Provider new-session commit detection is correlation-free. Replace "first unseen session wins" with a client-chosen id, server-returned id, or explicit mapping event, and test unrelated session arrival races.
6. `AgentHostSessionHandler` remains too large and duplicates child tool lifecycle handling. Extract shared turn/tool progress tracking and add child-session parity tests for terminal tools, file edits, cancellation, result confirmation, and reconnect.
7. Customization sync is split and hooks are silently dropped. Centralize classification/bundling/update orchestration and either implement hook merging or surface hooks as unsupported.
8. `AgentSubscriptionManager` has type/API footguns: root passed to `getSubscription`, errors that may not notify listeners, and `any` storage. Tighten the API and tests.
9. Protocol mirror validation can drift from `agent-host-protocol`. Add a clean-sync/hash or compile-only validation check.
10. Runtime protocol extension methods remain outside generated protocol typing beyond this client's local map. Decide whether `shutdown` belongs in AHP or in a shared VS Code extension-command map used by both client and server.
11. Remote service APIs still advertise `IAgentConnection` while implementations downcast to `RemoteAgentHostProtocolClient`. Make the interface honest or introduce a narrower remote-client interface.
12. Relay transport close semantics are drifting. Add shared tests for WebSocket, SSH relay, and tunnel relay close/error/dispose behavior before refactoring.
13. `AgentSideEffects` can leave queued diff work alive after disposal. Add cancellation/disposed checks and tests proving no dispatch/DB ref after dispose.
14. `BaseAgentHostSessionsProvider._handleConfigChanged` still has the old fallback schema path. Decide whether lazy config seeding makes it removable.
15. Tests still contain real sleeps and timing-coupled microtask nudges. Replace with faked timers or explicit synchronization helpers.

## Test coverage notes

VS Code-side Agent Host coverage was run over platform, workbench agent-session, workbench agent-host, sessions agent-host, and remote-agent-host test slices. Initial result: 267 tests passed, 0 failed. The protocol repo's `npm test` also passed typecheck/lint and 176 tests, with `types/reducers.ts` at 100% coverage.

Important initial hotspot coverage:

- `agentSubscription.ts`: 93.8% - strong optimistic subscription coverage.
- `protocolServerHandler.ts`: 81.2% - weak around handshake/reverse RPC/reconnect/extension/unknown paths.
- `remoteAgentHostSessionsProvider.ts`: 85.5% - thin around browse/connect-on-demand and some remote URI/action edges.
- `baseAgentHostSessionsProvider.ts`: 71.6% - shared provider behavior needs more race/config/cache coverage.
- `stateToProgressAdapter.ts`: 68.6% - terminal/subagent/file-edit/confirmation branches remain sparse.
- `agentHostSessionHandler.ts`: 66.2% - largest risky adapter; many turn, client-tool, subagent, terminal, file-edit, and reconnect branches uncovered.
- `syncedCustomizationBundler.ts`: 100.0% for current behavior, though hooks remain unsupported/debt.

Before the cleanup, `remoteAgentHostProtocolClient.ts` and `webSocketClientTransport.ts` did not appear in detailed coverage and had no focused tests. After the cleanup, focused coverage for `remoteAgentHostProtocolClient.test.ts` passed 13/13 and reported `remoteAgentHostProtocolClient.ts` at 61.8% statement coverage. `remoteAgentHostService.test.ts` passed 19/19, and the broader Agent Host slice passed 151/151.

## Doc updates

- Added [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md) with lifecycle rules, disposal-order gotcha, extension-request typing, tests, and remaining remote debt.
- Updated [index](../../index.md) to list the new remote client doc and point cross-cutting active debt at it.
- Cleaned up the temporary `plan/2026-04-21-agent-host-debt-audit/` and `plan/2026-04-21-remote-protocol-client-lifecycle/` folders after copying the durable notes here.
