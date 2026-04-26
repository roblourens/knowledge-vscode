# Testing the Agent Host

_Covers: src/vs/platform/agentHost/test/, src/vs/workbench/contrib/chat/test/browser/agentSessions/, src/vs/workbench/contrib/chat/test/browser/agentHost/, src/vs/sessions/test/_

The agent host has four distinct test layers, each with its own runner, scope, and trade-offs. Pick the lowest layer that can express the regression you care about — higher layers are slower, flakier, and less precise about *what* broke.

## The four layers

### 1. Unit tests (`*.test.ts`)

**What they exercise:** A single class or function in isolation. Dependencies are stubbed or replaced with in-memory fakes (see `MockAgent`, `TestAgentHostStateManager`, `TestableCopilotAgent` etc.). No protocol process is spawned.

**Where they live:**
- Platform layer: `src/vs/platform/agentHost/test/node/*.test.ts`
- Workbench adapters: `src/vs/workbench/contrib/chat/test/browser/agentSessions/**/*.test.ts`, `src/vs/workbench/contrib/chat/test/browser/agentHost/*.test.ts`
- Sessions app: `src/vs/sessions/test/**/*.test.ts`
- UI content parts: `src/vs/workbench/contrib/chat/test/browser/widget/chatContentParts/*.test.ts`

**How to run:**
```sh
unset ELECTRON_RUN_AS_NODE
./scripts/test.sh --grep "<pattern>"   # macOS / Linux
./scripts/test.bat --grep "<pattern>"  # Windows
```
Pattern matches mocha suite/test names. Examples: `--grep "AgentSideEffects|AgentEventMapper"`, `--grep "ChatSubagentContentPart"`. Always `unset ELECTRON_RUN_AS_NODE` first or the runner picks up the wrong binary path.

**When to use:**
- Default. Reach for unit tests first.
- Anything you can express by feeding events/actions into a class and asserting on the resulting state. Most agent host bugs land here — `agentSideEffects.ts` event routing, `stateToProgressAdapter.ts` rendering, `chatSubagentContentPart.ts` UI updates, mapper output shapes.
- Behaviorally driving private state — don't reach into private fields, fire the public events that exercise the state path and assert on observable outcomes (see the `_pendingSubagentEvents` regression test in `agentSideEffects.test.ts` for an example).

**When *not* to use:**
- Multi-client / connection-layer behavior. Use protocol integration tests.
- Anything that depends on real SDK message ordering or wall-clock semantics. Use real-SDK integration tests.

### 2. Protocol integration tests (`*.integrationTest.ts`)

**What they exercise:** A real Agent Host server process started by `startServer()`, talking to one or more in-test clients via WebSocket. Agents are mocked via `ScriptedMockAgent` (the `--enable-mock-agent` flow), so the *protocol* is exercised end-to-end but no SDK is involved.

**Where they live:** `src/vs/platform/agentHost/test/node/protocol/*.integrationTest.ts`. Existing files include `handshake`, `sessionLifecycle`, `sessionFeatures`, `sessionConfig`, `turnExecution`, `toolApproval`, `clientTools`, `multiClient`, `agentHostServer`.

**How to run:**
```sh
unset ELECTRON_RUN_AS_NODE
node build/next/index.ts transpile   # required after editing TS
./scripts/test-integration.sh --runGlob '**/agentHost/**/*.integrationTest.js'
# or filter further:
./scripts/test-integration.sh --runGlob '**/turnExecution.integrationTest.js'
```

**When to use:**
- Protocol shape changes (action envelopes, command parameters, capability negotiation).
- Multi-client concurrency, server-initiated turns, reconnect/replay, action ordering across the wire.
- Subagent / tool-call routing where the realistic path is "client subscribes, server emits a sequence, client observes the resulting state". The session-features test for `subagent: inner tool calls land in child session, not parent` is the canonical example.

**When *not* to use:**
- Anything you can express against the in-process state manager directly. Unit tests are 10× faster.

**Adding a scenario:** Most new scenarios are best added by extending an existing prompt case in `ScriptedMockAgent` (`src/vs/platform/agentHost/test/node/mockAgent.ts`) — find a `case '<promptKey>':` block, then drive the new prompt from a test in the appropriate `*.integrationTest.ts` file. The `subagent` case is a worked example.

### 3. Real-SDK integration tests (`toolApprovalRealSdk.integrationTest.ts`)

**What they exercise:** The full agent host **with the real Copilot SDK**, against a live GitHub Copilot endpoint. Catches problems that only surface in the SDK's actual event ordering, error shapes, and tool argument schemas (e.g. that the `task` tool emits `agent_type` not `agentName`).

**Where they live:** `src/vs/platform/agentHost/test/node/protocol/toolApprovalRealSdk.integrationTest.ts`. Add new scenarios here rather than creating new real-SDK files — keeping them in one place makes the env-gating and auth setup explicit.

**How to run:** Disabled by default; gated on `AGENT_HOST_REAL_SDK=1`:
```sh
AGENT_HOST_REAL_SDK=1 ./scripts/test-integration.sh \
    --run src/vs/platform/agentHost/test/node/protocol/toolApprovalRealSdk.integrationTest.ts
```
Auth comes from `gh auth token` by default; override with `GITHUB_TOKEN`.

**Safety:** These tests really call out to a real agent that really runs tools on the developer's machine. Prompts must be carefully bounded — read-only questions, `echo` commands, isolated temp directories. **Never** ask the agent to delete, modify, or install anything outside a test-owned temp dir. The file header documents this; respect it.

**When to use:**
- Validating that an SDK-specific assumption (event names, tool arg shapes, error envelopes) actually holds. The fix that moved subagent arg parsing into `copilotToolDisplay.ts::getSubagentMetadata` was driven by adding a real-SDK assertion that `agent_type` is what the SDK actually emits.
- Catching regressions in SDK adapter code (`copilot/copilotAgentSession.ts`, `copilot/mapSessionEvents.ts`, `copilot/copilotToolDisplay.ts`) before they hit users.
- **Catching SDK type-vs-schema drift.** The bundled `@github/copilot` server's runtime JSON schema can diverge from `@github/copilot-sdk`'s `.d.ts` types within a single release line — at `@github/copilot@1.0.34` the synthetic `auto` router model is returned by `listModels()` with `capabilities: {}` (no `limits`, no `supports`), even though the SDK type declares all of them required. Direct dereferences like `m.capabilities.limits.max_context_window_tokens` throw `TypeError` at runtime on the first such model. The `listModels returns well-shaped model entries after authenticate` test asserts the `auto` model is in the returned list and tolerates `maxContextWindow: undefined`. The fix at the consumer side is the `ICopilotModelInfo` wrapper interface in `copilotAgent.ts` (re-declares the same fields with optional sub-objects) plus `IAgentModelInfo.maxContextWindow?: number` — see [copilot-agent-provider gotcha](./copilot-agent-provider.md#debt--gotchas). Add similar shape-asserting tests when adding new SDK-typed dereferences in adapter code.

**When *not* to use:**
- For routine logic. The auth-and-network hop makes them slow and occasionally flaky; CI does not run them by default.
- Any test that doesn't genuinely depend on the real SDK behavior. If a `ScriptedMockAgent` event sequence captures the contract, prefer the protocol integration test instead.

### 4. Workbench / chat / UI tests

**What they exercise:** The workbench-side adapters that translate AHP state into VS Code chat sessions, edits, and UI. They run under the same unit-test runner (`./scripts/test.sh`) but interact with `IAgentConnection`, `ChatService`, content parts, and the editing session.

**Where they live:**
- `agentHostChatContribution.test.ts` — handler dispatch, progress rendering, active-turn reconnect, server-initiated turns, customizations.
- `agentHostClientTools.test.ts` — tool definition/result conversion, allowlist filtering.
- `agentHostEditingSession.test.ts` — file edit hydration, undo/redo, snapshots.
- `chatSubagentContentPart.test.ts` — late metadata updates, lazy expand, current-running-tool title, etc.

**When to use:**
- Workbench-side behavior that reads protocol state but never goes over the wire (the connection is mocked).
- Anything UI-shaped: title rendering, expansion behavior, hover content. The `Late metadata updates` suite in `chatSubagentContentPart.test.ts` is the worked example for "construct a part, mutate the invocation, assert on the rendered title".

## Decision tree: which layer?

```
Does it depend on the real Copilot SDK's wire behavior?
  → real-SDK integration test (toolApprovalRealSdk.integrationTest.ts)
Does it depend on multi-client, server-initiated, reconnect, or wire-format ordering?
  → protocol integration test (*.integrationTest.ts + ScriptedMockAgent)
Does it render or update workbench chat UI / content parts?
  → workbench unit test (agentHost*.test.ts, chatSubagentContentPart.test.ts)
Otherwise — single class or function, drive with events, assert on state?
  → platform unit test (agentHost/test/node/*.test.ts)
```

## Workflow tips

- **`unset ELECTRON_RUN_AS_NODE`** before `./scripts/test.sh` and `./scripts/test-integration.sh`. Otherwise the runner reuses the host process and fails opaquely.
- **Always retranspile** after TS edits before running integration tests: `node build/next/index.ts transpile`. Unit tests via `./scripts/test.sh` retranspile internally; **but `node test/unit/node/index.js` does NOT — it runs the existing compiled `out/`**. After editing source, you must explicitly recompile (`npx tsc -p src --outDir out`) before invoking the unit runner directly, or you can silently get green tests against stale code that mask a real failure CI catches against fresh build. `npm run compile-check-ts-native` only type-checks, it doesn't emit.
- **Type-check first**: `npm run compile-check-ts-native` is fast (≈3s) and catches a class of bugs before the runner even starts. Run it before any test command.
- **Reproduce regression tests by reverting the fix.** When adding a regression test for a bug you just fixed, briefly revert the fix and confirm the test fails — it's the only way to be sure the test actually exercises the broken path. Restore the fix immediately after.
- **Prefer behavioral tests over private-field probes.** If a class stores something on a private map, drive the events that fill the map and assert on observable behavior (state, dispatched actions, follow-up events) rather than reading the map. The cleanup test in `agentSideEffects.test.ts` does this for `_pendingSubagentEvents`.

## Related

- [agent-host-protocol](./agent-host-protocol.md) — the contract that protocol integration tests exercise.
- [agent-host-session-handler](./agent-host-session-handler.md) — the workbench adapter that workbench/UI tests cover.
- [copilot-agent-provider](./copilot-agent-provider.md) — the SDK adapter that real-SDK integration tests guard.

## Debt & gotchas

- **gotcha** (2026-04-22, agentHostChatContribution.test.ts:MockAgentHostService) — TypeScript class fields are initialized **top-to-bottom**. If a field initializer references another field (e.g. `rootState = { ... onDidChange: this._rootStateOnDidChange.event ... }`), the referenced field **must be declared first** or you'll hit `Cannot read properties of undefined (reading 'event')` at runtime. In `MockAgentHostService` this means `_rootStateOnDidChange: Emitter<...>` must be declared before `rootState`. The TypeScript compiler does not warn about this.
- **gotcha** (2026-04-21, protocol/toolApprovalRealSdk.integrationTest.ts) — gated on `AGENT_HOST_REAL_SDK=1` and not run by CI, so any string identifier embedded in this file (provider ids, agent names, well-known config keys) can sit broken indefinitely after a rename — TypeScript doesn't catch it (the API parameters are typed as plain `string`) and the suite never runs unattended. When renaming anything in the agent host that has a corresponding string in this file, manually run the full suite (`AGENT_HOST_REAL_SDK=1 ./scripts/test-integration.sh --runGlob "**/agentHost/**/toolApprovalRealSdk.integrationTest.js"`) and grep the file for the old name.
- **gotcha** (2026-04-22, protocol/toolApprovalRealSdk.integrationTest.ts:`planning-mode session-state writes are auto-approved in default mode`) — currently `test.skip`'d. The public `@github/copilot-sdk` has no way to enter plan mode (`MessageOptions` has no `agentMode` field) and no `Session.respondToExitPlanMode()` method, so even when the SDK emits `exit_plan_mode.requested` (the event type IS in the public union), there's no responder API. The extension uses the **private** `@github/copilot/sdk` which has both surfaces — see [copilot-agent-provider gotcha](./copilot-agent-provider.md#debt--gotchas) on the public/private SDK split. Re-enable the test once the public SDK surfaces plan-mode entry/exit. Don't be fooled by the `onExitPlanMode` callback in `SessionOptions` either: in the public SDK it's `protected` and not exposed via `ResumeSessionConfig` — that's a private-only callback path.
- **gotcha** (2026-04-22, protocol/toolApprovalRealSdk.integrationTest.ts:`subagent` background `approvalLoop`) — `client.waitForNotification(predicate, timeout)` does NOT consume notifications from its queue when the predicate matches; it only filters them. Any background loop that polls for an event class (e.g. `session/toolCallReady`) and acts on it must dedupe by `getActionEnvelope(n).serverSeq` and skip already-handled seqs in *both* the predicate and the action guard, or it busy-spins on the same notification forever and the loop never times out. Deduping by domain id (e.g. `toolCallId`) is wrong: the same id can legitimately appear in multiple notifications (e.g. re-confirmation while the tool runs).
- **gotcha** (2026-04-22, protocol/toolApprovalRealSdk.integrationTest.ts) — when asserting on shell-command text the SDK emitted, anchor the regex with `^` and explicitly tolerate quoted variants (`cd "<dir>"` vs `cd <dir>`) and both chain operators (`&&` and `;`). A naked `String.includes("cd " + tempDir)` substring check misses quoted forms and is also tripped by tempDir appearing later in the same command. The cd-prefix-strip test uses `new RegExp('^cd (?:"' + esc + '"|' + esc + ')\\s*(?:&&|;)')` against the rewritten and the original command lines.

## Changelog

- **2026-04-25** — 89433a4490 — clarified the retranspile workflow tip: `node test/unit/node/index.js` runs the existing `out/` and does NOT retranspile, so editing source and rerunning the direct runner can give a stale-but-green result that CI then catches. Type-check (`compile-check-ts-native`) is not enough — must `npx tsc -p src --outDir out`. Caught the hard way when test snapshot updates passed locally and failed CI.
- **2026-04-22** — `357bfe70c9` — added gotcha for real-SDK shell-command assertions: anchor the regex with `^` and tolerate quoted (`cd "<dir>"`) and unquoted forms plus both `&&` / `;` chain operators, since a substring `.includes("cd " + tempDir)` check both misses quoted variants AND mis-fires on later occurrences of `tempDir`. From the cd-prefix-strip real-SDK test (see [changes/2026-04-22-agent-host-cd-cleanup](../changes/2026-04-22-agent-host-cd-cleanup/summary.md)).

- **2026-04-24** — `5407371c47` — reconciliation: no doc changes. New unit tests added since baseline (`agentConfigurationService.test.ts`, `agentHostSchema.test.ts`, `agentSessionSettingsFileSystemProvider.test.ts`, additional `remoteAgentHostProtocolClient` coverage) all fit cleanly into the existing four-layer model. The `c10232daea7` (real-SDK fixes) and `c08fa679e25` (per-key `setMetadata` sequencing) commits reinforce the existing gotchas about real-SDK drift and timing-sensitive tests; no prose change needed.

- **2026-04-22** — `67763f6b5e` — added gotcha about TypeScript class field initialization order in `MockAgentHostService`.
- **2026-04-22** — `a92cbe70e9` — replaced the joint `planning-mode` + `subagent` failing-tests gotcha with two more precise entries: `subagent` is now fixed (busy-spin from `waitForNotification` not consuming matched notifications; dedupe by `serverSeq`); `planning-mode` is `test.skip`'d because the public `@github/copilot-sdk` lacks `agentMode` on `MessageOptions` and `respondToExitPlanMode()` on `Session` — see the new public/private SDK split gotcha in [copilot-agent-provider](./copilot-agent-provider.md#debt--gotchas). Added a standalone gotcha about `waitForNotification` not consuming, since it's a class of bug that catches background-polling loops in any real-SDK or protocol-integration test.
- **2026-04-22** — `d6e5c5227d` — refreshed the `listModels` SDK type-vs-schema drift example: at `@github/copilot@1.0.34` the offender is the synthetic `auto` model (entire `capabilities` empty), not a missing `limits`; the consumer-side fix is the new `ICopilotModelInfo` wrapper plus optional `IAgentModelInfo.maxContextWindow`. The same `listModels` test now also asserts that `auto` is in the returned list and tolerates `maxContextWindow: undefined`.
- **2026-04-21** — `4da62d3b09` — added `listModels` example to "When to use" in section 3 (real-SDK tests catch SDK type-vs-schema drift); added gotchas about the env-gated real-SDK file's invisibility to CI (rename audit risk) and the two known-broken tests in that suite.
- **2026-04-19** — `2935e7d695` — initial entry. Documents the four test layers (unit, protocol integration, real-SDK integration, workbench/UI), how to run each, when to pick which, and workflow gotchas (`unset ELECTRON_RUN_AS_NODE`, retranspile before integration runs, regression tests should be verified by briefly reverting the fix).
