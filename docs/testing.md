# Testing the Agent Host

_Covers: src/vs/platform/agentHost/test/, src/vs/workbench/contrib/chat/test/browser/agentSessions/, src/vs/workbench/contrib/chat/test/browser/agentHost/, src/vs/sessions/test/_

The agent host has four distinct test layers, each with its own runner, scope, and trade-offs. Pick the lowest layer that can express the regression you care about — higher layers are slower, flakier, and less precise about *what* broke.

## The four layers

### 1. Unit tests (`*.test.ts`)

**What they exercise:** A single class or function in isolation. Dependencies are stubbed or replaced with in-memory fakes (see `MockAgent`, `TestAgentHostStateManager`, `TestableCopilotAgent` etc.). No protocol process is spawned.

**Where they live:**
- Platform layer: `src/vs/platform/agentHost/test/node/*.test.ts`
- Shared/common helpers: `src/vs/platform/agentHost/test/common/*.test.ts`
- Workbench adapters: `src/vs/workbench/contrib/chat/test/browser/agentSessions/**/*.test.ts`, `src/vs/workbench/contrib/chat/test/browser/agentHost/*.test.ts`. `agentSessions/agentHostPermissionUiContribution.test.ts` covers the remote-host local-file permission prompt bridge.
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

### 3. Real-SDK integration tests (`*RealSdk.integrationTest.ts` + `realSdkTestHelpers.ts`)

**What they exercise:** The full agent host **with real vendor SDKs**, against live provider endpoints. Catches problems that only surface in SDK event ordering, error shapes, and tool argument schemas (e.g. that Copilot's `task` tool emits `agent_type` not `agentName`).

**Where they live:** `src/vs/platform/agentHost/test/node/protocol/copilotRealSdk.integrationTest.ts` and `claudeRealSdk.integrationTest.ts`, with cross-provider scenarios in `realSdkTestHelpers.ts`. Add shared cases to the helper and provider-specific assertions to the matching provider entrypoint so env-gating, auth, and vendor quirks stay explicit.

**How to run:** Disabled by default; gated on `AGENT_HOST_REAL_SDK=1`. **Always `unset ELECTRON_RUN_AS_NODE` first** — the runner crashes immediately at `test/unit/electron/index.js:119` (`TypeError: Cannot read properties of undefined (reading 'setPath')`) if it's set, because Electron's `app` API is stripped in node-mode and that var leaks in from VS Code / `npm`-spawned shells:
```sh
unset ELECTRON_RUN_AS_NODE
AGENT_HOST_REAL_SDK=1 ./scripts/test-integration.sh \
  --run src/vs/platform/agentHost/test/node/protocol/copilotRealSdk.integrationTest.ts
```
Use `claudeRealSdk.integrationTest.ts` instead when you are validating the Claude provider. Add `--grep "<test name>"` to focus on a single test (`listModels`, `cd-prefix`, etc.) — without it the selected real-SDK suite runs and takes minutes.

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
  → real-SDK integration test (*RealSdk.integrationTest.ts + realSdkTestHelpers.ts)
Does it depend on multi-client, server-initiated, reconnect, or wire-format ordering?
  → protocol integration test (*.integrationTest.ts + ScriptedMockAgent)
Does it render or update workbench chat UI / content parts?
  → workbench unit test (agentHost*.test.ts, chatSubagentContentPart.test.ts)
Otherwise — single class or function, drive with events, assert on state?
  → platform unit test (agentHost/test/node/*.test.ts)
```

## Workflow tips

- **`unset ELECTRON_RUN_AS_NODE`** before `./scripts/test.sh` and `./scripts/test-integration.sh`. Otherwise the runner reuses the host process and fails opaquely.
- **Always retranspile after TS edits — `./scripts/test.sh` does NOT compile.** The unit runner (`./scripts/test.sh`, and `node test/unit/node/index.js`) runs the **existing compiled `out/`**; `test.sh` only launches Electron and the runner, with no transpile step. It relies on a `npm run watch` (or `watch-client-transpile`) daemon keeping `out/` fresh. If no watch is running **for this checkout** — or a watch from another checkout is attached and silently not updating yours — you get green tests against stale code (e.g. a brand-new test "passing" because it isn't even in `out/`, masking a real failure CI catches against a fresh build). After editing source, either confirm the watch is live for this tree, or explicitly rebuild: `node build/next/index.ts transpile` (fast, esbuild; what the integration runners also require). Sanity-check freshness by grepping the compiled `out/...js` for a symbol you just added. `npm run compile-check-ts-native` only type-checks, it doesn't emit.
- **Type-check first**: `npm run compile-check-ts-native` is fast (≈3s) and catches a class of bugs before the runner even starts. Run it before any test command.
- **Reproduce regression tests by reverting the fix.** When adding a regression test for a bug you just fixed, briefly revert the fix and confirm the test fails — it's the only way to be sure the test actually exercises the broken path. Restore the fix immediately after.
- **Prefer behavioral tests over private-field probes.** If a class stores something on a private map, drive the events that fill the map and assert on observable behavior (state, dispatched actions, follow-up events) rather than reading the map. The cleanup test in `agentSideEffects.test.ts` does this for `_pendingSubagentEvents`.

## Exploratory UI testing via the launch skill

The four layers above cover automated tests. For exploratory work — bug-bashing the running Agents window, validating that a multi-turn flow renders correctly, or reproducing a specific UI symptom against the real SDK — the canonical tool is the `launch` skill at `.agents/skills/launch/SKILL.md` in the VS Code repo. It launches Code OSS from sources into a slim-copied throwaway profile with unique debug ports, and drives the UI via `@playwright/cli` over CDP.

This is not a substitute for automated tests, but it has caught classes of issues the four layers can't reach: tool-card rendering across multi-command turns, cancellation UX, session restore across process restart, approval-prompt visual layout, etc. Treat any finding from an exploratory run as a candidate for an automated test at one of the four layers above before declaring it "fixed".

Three coordination details bite if missed (each surfaced in the 2026-05-26 terminal-tool bug bash):

- **`files.simpleDialog.enable=true`** must be set in the launched profile. Without it, the new-session workspace picker's `Select…` action opens a native OS file dialog that is unreachable over CDP/SSH. The launch script applies this automatically as of `e6e488e018`.
- **Pass `-s=$PW_SESSION`** (or `--session NAME`) on every `npx @playwright/cli ...` call when more than one Code OSS is running. The CLI runs a persistent per-session daemon (`cliDaemon.js`) keyed by session name; un-flagged callers all share the implicit `"default"` daemon and the most-recently-attached CDP wins for every subsequent command from any of those shells. The `monaco-paste.sh` helper honors the same flag and the `PW_SESSION` env var.
- **macOS Mach-ports concurrency limit** caps usable parallel Code OSS instances at roughly 2–3 on a typical workstation. Beyond that, Crashpad's exception handler dies in a tight `mach_port_request_notification: invalid capability` loop and one or more instances become CDP-unresponsive. Not affected by session naming — it's an OS-level resource. Sequential or small-batch parallel runs are the practical answer.

## Related

- [agent-host-protocol](./agent-host-protocol.md) — the contract that protocol integration tests exercise.
- [agent-host-session-handler](./agent-host-session-handler.md) — the workbench adapter that workbench/UI tests cover.
- [copilot-agent-provider](./copilot-agent-provider.md) — the SDK adapter that real-SDK integration tests guard.

## Debt & gotchas

- **debt** (2026-04-26, agentHostDiffs.ts) — `src/vs/sessions/contrib/providers/agentHost/browser/agentHostDiffs.ts` has **no unit tests**. It contains `diffsToChanges` (which must correctly handle `added`, `modified`, `deleted`, and `renamed` statuses) and `diffsEqual`. Two bugs were shipped and caught manually in the running product: (1) added-file bug — `originalUri` was set to a `git-blob:` URI with an invalid path for the "before" side of a new file; (2) deleted-file bug — `modifiedUri` was set to the pre-deletion real path, causing the diff editor to throw "Unable to resolve nonexistent file". A `agentHostDiffs.test.ts` covering all four statuses with both `mapUri` present and absent would have caught both. See [agent-host-git-driven-diffs](./agent-host-git-driven-diffs.md#debt--gotchas).
- **gotcha** (2026-04-22, agentHostChatContribution.test.ts:MockAgentHostService) — TypeScript class fields are initialized **top-to-bottom**. If a field initializer references another field (e.g. `rootState = { ... onDidChange: this._rootStateOnDidChange.event ... }`), the referenced field **must be declared first** or you'll hit `Cannot read properties of undefined (reading 'event')` at runtime. In `MockAgentHostService` this means `_rootStateOnDidChange: Emitter<...>` must be declared before `rootState`. The TypeScript compiler does not warn about this.
- **gotcha** (2026-04-21, protocol/*RealSdk.integrationTest.ts + realSdkTestHelpers.ts) — gated on `AGENT_HOST_REAL_SDK=1` and not run by CI, so any string identifier embedded in these files (provider ids, agent names, well-known config keys) can sit broken indefinitely after a rename — TypeScript doesn't catch it (the API parameters are typed as plain `string`) and the suites never run unattended. When renaming anything in the agent host that has a corresponding string in these files, manually run the affected suite (remember to `unset ELECTRON_RUN_AS_NODE` first; see § 3 for the full invocation) and grep the real-SDK files for the old name.
- **gotcha** (2026-04-22, protocol/realSdkTestHelpers.ts:`planning-mode session-state writes are auto-approved in default mode`) — providers that do not surface plan mode run this as `test.skip`. The public `@github/copilot-sdk` has no way to enter plan mode (`MessageOptions` has no `agentMode` field) and no `Session.respondToExitPlanMode()` method, so even when the SDK emits `exit_plan_mode.requested` (the event type IS in the public union), there's no responder API. The extension uses the **private** `@github/copilot/sdk` which has both surfaces — see [copilot-agent-provider gotcha](./copilot-agent-provider.md#debt--gotchas) on the public/private SDK split. Re-enable a provider's path once that provider surfaces plan-mode entry/exit. Don't be fooled by the `onExitPlanMode` callback in `SessionOptions` either: in the public SDK it's `protected` and not exposed via `ResumeSessionConfig` — that's a private-only callback path.
- **gotcha** (2026-04-22, protocol/realSdkTestHelpers.ts:startBackgroundApprovalLoop) — `client.waitForNotification(predicate, timeout)` does NOT consume notifications from its queue when the predicate matches; it only filters them. Any background loop that polls for an event class (e.g. `session/toolCallReady`) and acts on it must dedupe by `getActionEnvelope(n).serverSeq` and skip already-handled seqs in *both* the predicate and the action guard, or it busy-spins on the same notification forever and the loop never times out. Deduping by domain id (e.g. `toolCallId`) is wrong: the same id can legitimately appear in multiple notifications (e.g. re-confirmation while the tool runs).
- **gotcha** (2026-05-28, build/linux/debian/dep-lists.ts vs CI surfaces) — the deb auto-deps allowlist check (`vscode-linux-x64-prepare-deb` in `gulpfile.vscode.linux.ts`, error string "The dependencies list has changed.") only runs in the **Azure DevOps pipeline**, not in the GitHub Actions PR CI that gates merges. PR-level `gh pr checks` looks all-green even when this is about to fail, and the AzDo failure surfaces hours later. When bumping anything that ships a prebuilt native module (`@github/copilot`'s `runtime.node`, `@vscode/sqlite3`, `native-watchdog`, etc.), proactively diff GLIBC tiers — e.g. `objdump -T <module>.node | grep -oE 'GLIBC_[0-9.]+' | sort -u` against the previous version — and update `build/linux/debian/dep-lists.ts` in the same PR. The same blind spot applies to RPM (`build/linux/rpm/dep-lists.ts`), though RPM resolution rules are looser and usually already cover newer symbols. Also worth knowing: Azure DevOps build logs require organizational auth; `web_fetch` returns only the sign-in page, and `gh pr checks` shows the failing job name but not its log body — you have to either follow the link in a browser or ask whoever opened the PR to paste the failing chunk.
- **gotcha** (2026-04-22, protocol/copilotRealSdk.integrationTest.ts) — when asserting on shell-command text the SDK emitted, anchor the regex with `^` and explicitly tolerate quoted variants (`cd "<dir>"` vs `cd <dir>`) and both chain operators (`&&` and `;`). A naked `String.includes("cd " + tempDir)` substring check misses quoted forms and is also tripped by tempDir appearing later in the same command. The cd-prefix-strip test uses `new RegExp('^cd (?:"' + esc + '"|' + esc + ')\\s*(?:&&|;)')` against the rewritten and the original command lines.

## Changelog

- **2026-06-27** — 5edb399a83 — corrected the retranspile tip: `./scripts/test.sh` does **not** compile (it only launches Electron + the runner against existing `out/`), contrary to the prior "retranspiles internally" claim. It relies on a `npm run watch` daemon for *this* checkout; a watch attached to a different checkout can leave `out/` silently stale, so a brand-new test "passes" because it isn't even compiled in. Recommend `node build/next/index.ts transpile` after edits and grepping `out/...js` for a just-added symbol to confirm freshness. Hit during the #318604 fix.

- **2026-06-25** — 09c18fe5c5 — reconciliation: the four test layers still hold. Recorded that two new in-tree agents brought substantial harness suites — Claude under `src/vs/platform/agentHost/test/node/claude*.test.ts` (+ `clientTools/claude*`) and Codex under `src/vs/platform/agentHost/test/node/codex/` — mirroring the Copilot provider test shape (unit + integration + real-SDK helpers).

- **2026-05-28** — dced3b17d10 — added gotcha that the deb auto-deps allowlist check (`vscode-linux-x64-prepare-deb`) only runs on Azure DevOps, not GitHub Actions PR CI, so a clean `gh pr checks` can still hide a deb-prepare failure. Discovered when the `@github/copilot` 1.0.49 → 1.0.55-3 bump in PR [#318683](https://github.com/microsoft/vscode/pull/318683) shipped a new `runtime.node` with `GLIBC_2.15` symbols, requiring a one-line `dep-lists.ts` bump that surfaced ~16h after the PR went green. Included an `objdump -T | grep GLIBC_` diagnostic recipe and a note on AzDo log access friction. See `changes/2026-05-28-bump-copilot-sdk-beta-8/summary.md`.

- **2026-05-26** — e6e488e018 — added "Exploratory UI testing via the launch skill" section after the four automated layers. Documents the launch skill as the canonical bug-bash surface and the three coordination details that bite if missed: `files.simpleDialog.enable`, `-s=$PW_SESSION` on every CLI call, and the macOS Mach-ports cap on concurrent instances. See `changes/2026-05-26-agent-host-terminal-tool-bug-bash/`.

- **2026-05-15** — 12443ea83d — reconciliation: refreshed the split Copilot/Claude real-SDK entrypoints plus shared helper after `0d23db45a18`, moved Agent Host provider paths, and kept the existing four-layer test model intact across newer Claude, completions, ping, and tool-display coverage.

- **2026-05-04** — 939d3f227c — reconciliation: added the common-helper test location and called out the new permission UI coverage from `c30ed7c4a51`; no workflow change for protocol-version, session-diff, shell, or restore tests added in `e1a89568eb2`, `fd6d37812b4`, `6bdca786907`, `882f02a7bd5`, and `8309b22051c` because they fit the existing four-layer model.

- **2026-05-01** — b2e6267136 — reconciliation: no body changes. New Claude/Copilot API/unit coverage and shell/restore tests fit the existing four-layer model; no new runner or workflow rule was introduced.
- **2026-04-28** — `5e0eb8ff17` — moved the `unset ELECTRON_RUN_AS_NODE` requirement inline into the § 3 real-SDK invocation block (was only in the workflow-tips section, easy to miss when copy-pasting); added an explicit `--grep "<test name>"` reminder so finalize sessions don't re-run the full suite for a single check; rewrote the rename-audit gotcha to point back at § 3 instead of repeating the bare command without the `unset`.

- **2026-04-26** — `b86149ad81` — added debt entry for `agentHostDiffs.ts` having no unit tests; two bugs (added-file and deleted-file diff rendering) were both caught manually in the product rather than by a test.
- **2026-04-25** — 89433a4490 — clarified the retranspile workflow tip: `node test/unit/node/index.js` runs the existing `out/` and does NOT retranspile, so editing source and rerunning the direct runner can give a stale-but-green result that CI then catches. Type-check (`compile-check-ts-native`) is not enough — must `npx tsc -p src --outDir out`. Caught the hard way when test snapshot updates passed locally and failed CI.
- **2026-04-24** — `5407371c47` — reconciliation: no doc changes. New unit tests added since baseline (`agentConfigurationService.test.ts`, `agentHostSchema.test.ts`, `agentSessionSettingsFileSystemProvider.test.ts`, additional `remoteAgentHostProtocolClient` coverage) all fit cleanly into the existing four-layer model. The `c10232daea7` (real-SDK fixes) and `c08fa679e25` (per-key `setMetadata` sequencing) commits reinforce the existing gotchas about real-SDK drift and timing-sensitive tests; no prose change needed.
- **2026-04-22** — `357bfe70c9` — added gotcha for real-SDK shell-command assertions: anchor the regex with `^` and tolerate quoted (`cd "<dir>"`) and unquoted forms plus both `&&` / `;` chain operators, since a substring `.includes("cd " + tempDir)` check both misses quoted variants AND mis-fires on later occurrences of `tempDir`. From the cd-prefix-strip real-SDK test (see [changes/2026-04-22-agent-host-cd-cleanup](../changes/2026-04-22-agent-host-cd-cleanup/summary.md)).

- **2026-04-22** — `67763f6b5e` — added gotcha about TypeScript class field initialization order in `MockAgentHostService`.
- **2026-04-22** — `a92cbe70e9` — replaced the joint `planning-mode` + `subagent` failing-tests gotcha with two more precise entries: `subagent` is now fixed (busy-spin from `waitForNotification` not consuming matched notifications; dedupe by `serverSeq`); `planning-mode` is `test.skip`'d because the public `@github/copilot-sdk` lacks `agentMode` on `MessageOptions` and `respondToExitPlanMode()` on `Session` — see the new public/private SDK split gotcha in [copilot-agent-provider](./copilot-agent-provider.md#debt--gotchas). Added a standalone gotcha about `waitForNotification` not consuming, since it's a class of bug that catches background-polling loops in any real-SDK or protocol-integration test.
- **2026-04-22** — `d6e5c5227d` — refreshed the `listModels` SDK type-vs-schema drift example: at `@github/copilot@1.0.34` the offender is the synthetic `auto` model (entire `capabilities` empty), not a missing `limits`; the consumer-side fix is the new `ICopilotModelInfo` wrapper plus optional `IAgentModelInfo.maxContextWindow`. The same `listModels` test now also asserts that `auto` is in the returned list and tolerates `maxContextWindow: undefined`.
- **2026-04-21** — `4da62d3b09` — added `listModels` example to "When to use" in section 3 (real-SDK tests catch SDK type-vs-schema drift); added gotchas about the env-gated real-SDK file's invisibility to CI (rename audit risk) and the two known-broken tests in that suite.
- **2026-04-19** — `2935e7d695` — initial entry. Documents the four test layers (unit, protocol integration, real-SDK integration, workbench/UI), how to run each, when to pick which, and workflow gotchas (`unset ELECTRON_RUN_AS_NODE`, retranspile before integration runs, regression tests should be verified by briefly reverting the fix).
