# Testing the Agent Host

_Covers: src/vs/platform/agentHost/test/, src/vs/workbench/contrib/chat/test/browser/agentSessions/, src/vs/workbench/contrib/chat/test/browser/agentHost/, src/vs/sessions/test/_

The agent host has four distinct test layers, each with its own runner, scope, and trade-offs. Pick the lowest layer that can express the regression you care about — higher layers are slower, flakier, and less precise about *what* broke.

## The four layers

### 1. Unit tests (`*.test.ts`)

**What they exercise:** A single class or function in isolation. Dependencies are stubbed or replaced with in-memory fakes (see `MockAgent`, `TestAgentHostStateManager`, `TestableCopilotAgent` etc.). No protocol process is spawned.

**Where they live:**
- Platform layer: `src/vs/platform/agentHost/test/node/*.test.ts`
- Shared/common helpers: `src/vs/platform/agentHost/test/common/*.test.ts`
- Renderer reverse-RPC/IPC channel registration: `src/vs/platform/agentHost/test/electron-browser/*.test.ts` (e.g. `localAgentHostService.test.ts` covers the BYOK language-model bridge channel registration degrading gracefully when a connecting window hasn't bound a handler).
- Workbench adapters: `src/vs/workbench/contrib/chat/test/browser/agentSessions/**/*.test.ts`, `src/vs/workbench/contrib/chat/test/browser/agentHost/*.test.ts`. `agentSessions/agentHostPermissionUiContribution.test.ts` covers the remote-host local-file permission prompt bridge.
- Agent window (Sessions layer): `src/vs/sessions/test/**/*.test.ts`
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

**Where they live:** `src/vs/platform/agentHost/test/node/protocol/*.integrationTest.ts`. Existing files include `handshake`, `sessionLifecycle`, `sessionFeatures`, `sessionConfig`, `turnExecution`, `toolApproval`, `clientTools`, `multiClient`, `agentHostServer`, `copilotCustomizations`.

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

### 3. Bundled-provider end-to-end tests (`*AgentHostE2E.integrationTest.ts`)

**What they exercise:** The complete Agent Host stack: a real server subprocess, the bundled Copilot / Claude / Codex SDK or CLI subprocess, real AHP over WebSocket, and real local tool execution. Only the language-model boundary is faked during normal runs. `CapiReplayProxy` serves committed normalized model replies, so the suites are deterministic, tokenless, network-free, and run in PR CI.

**Where they live:** Provider entrypoints are `copilotAgentHostE2E.integrationTest.ts`, `claudeAgentHostE2E.integrationTest.ts`, and `codexAgentHostE2E.integrationTest.ts`; shared behavior and lifecycle live in `agentHostE2ETestHelpers.ts`. `capiReplayProxy.ts` / `capiWireCodec.ts` own LLM fixtures under `captures/agentHostE2E/`. `ahpSnapshot.ts` owns executable semantic AHP snapshots under `__snapshots__/`.

**How to run:**
```sh
unset ELECTRON_RUN_AS_NODE
./scripts/test-integration.sh --run \
  src/vs/platform/agentHost/test/node/protocol/copilotAgentHostE2E.integrationTest.ts
```
Add `--grep "<test name>"` to focus a scenario. Replay is the default and strict: an unrecorded model request is a hard cache miss, never a fallback to real CAPI.

**Two recorded boundaries:**
- The per-test LLM fixture stores normalized request summaries plus regeneratable model replies. It omits volatile token counts, normalizes temp paths / UUIDs / tool-call ids, and records the wire dialect once.
- An AHP snapshot is an executable sequence of rounds. Each round's `clientToServer` actions are test input; `serverToClient` is expected semantic traffic, with the final server entry acting as the synchronization boundary before the next round.

`AhpSnapshotRecorder` normalizes resource and turn ids, excludes high-frequency environment-dependent notifications, and coalesces `chat/responsePart` plus `chat/delta` into final content. This semantic normalization is what lets the same AHP snapshot describe both live recording and deterministic replay despite different SSE chunk boundaries.

**Updating:**
```sh
# Tokenless: update only AHP output from existing LLM replay.
AGENT_HOST_UPDATE_AHP_SNAPSHOTS=1 ./scripts/test-integration.sh --run <provider-file> --grep "<test>"

# Needs a GitHub token: update LLM + AHP in one live run.
AGENT_HOST_UPDATE_SNAPSHOTS=1 ./scripts/test-integration.sh --run <provider-file> --grep "<test>"

# Update only LLM fixtures.
AGENT_HOST_REPLAY_RECORD=1 ./scripts/test-integration.sh --run <provider-file> --grep "<test>"
```
The combined update deliberately skips record-only scenarios such as mid-turn abort. Scope updates with `--grep` unless every scenario in the provider file should be re-recorded; provider-default model changes can otherwise rewrite the whole fixture set.

**When to use:** SDK/CLI event ordering, runtime schemas, provider tool behavior, protocol-to-provider integration, session persistence/resume, worktree isolation, and other behavior whose value comes from running through the real provider process. Prefer lower-layer protocol or unit tests when a mock can express the contract precisely.

**Safety:** Real-CAPI recording creates real sessions and really executes tools. Prompts must remain trivial/read-only and filesystem work must stay inside test-owned temporary directories.

`copilotAgentHostE2EMocked.integrationTest.ts` remains a smaller real-Copilot-process suite backed by the in-repo mock LLM server.

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
Does it depend on a bundled provider SDK/CLI's runtime behavior?
  → bundled-provider E2E test (*AgentHostE2E.integrationTest.ts)
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

The four layers above cover automated tests. For exploratory work — bug-bashing the running agent window, validating that a multi-turn flow renders correctly, or reproducing a specific UI symptom against the real SDK — the canonical tool is the `launch` skill at `.agents/skills/launch/SKILL.md` in the VS Code repo. It launches Code OSS from sources into a slim-copied throwaway profile with unique debug ports, and drives the UI via `@playwright/cli` over CDP.

This is not a substitute for automated tests, but it has caught classes of issues the four layers can't reach: tool-card rendering across multi-command turns, cancellation UX, session restore across process restart, approval-prompt visual layout, etc. Treat any finding from an exploratory run as a candidate for an automated test at one of the four layers above before declaring it "fixed".

Three coordination details bite if missed (each surfaced in the 2026-05-26 terminal-tool bug bash):

- **`files.simpleDialog.enable=true`** must be set in the launched profile. Without it, the new-session workspace picker's `Select…` action opens a native OS file dialog that is unreachable over CDP/SSH. The launch script applies this automatically as of `e6e488e018`.
- **Pass `-s=$PW_SESSION`** (or `--session NAME`) on every `npx @playwright/cli ...` call when more than one Code OSS is running. The CLI runs a persistent per-session daemon (`cliDaemon.js`) keyed by session name; un-flagged callers all share the implicit `"default"` daemon and the most-recently-attached CDP wins for every subsequent command from any of those shells. The `monaco-paste.sh` helper honors the same flag and the `PW_SESSION` env var.
- **macOS Mach-ports concurrency limit** caps usable parallel Code OSS instances at roughly 2–3 on a typical workstation. Beyond that, Crashpad's exception handler dies in a tight `mach_port_request_notification: invalid capability` loop and one or more instances become CDP-unresponsive. Not affected by session naming — it's an OS-level resource. Sequential or small-batch parallel runs are the practical answer.

## Related

- [agent-host-protocol](./agent-host-protocol.md) — the contract that protocol integration tests exercise.
- [agent-host-session-handler](./agent-host-session-handler.md) — the workbench adapter that workbench/UI tests cover.
- [copilot-agent-provider](./copilot-agent-provider.md) — the SDK adapter that bundled-provider E2E tests guard.

## Debt & gotchas

- **debt** (2026-04-26, agentHostDiffs.ts) — `src/vs/sessions/contrib/providers/agentHost/browser/agentHostDiffs.ts` has **no unit tests**. It contains `diffsToChanges` (which must correctly handle `added`, `modified`, `deleted`, and `renamed` statuses) and `diffsEqual`. Two bugs were shipped and caught manually in the running product: (1) added-file bug — `originalUri` was set to a `git-blob:` URI with an invalid path for the "before" side of a new file; (2) deleted-file bug — `modifiedUri` was set to the pre-deletion real path, causing the diff editor to throw "Unable to resolve nonexistent file". A `agentHostDiffs.test.ts` covering all four statuses with both `mapUri` present and absent would have caught both. See [agent-host-git-driven-diffs](./agent-host-git-driven-diffs.md#debt--gotchas).
- **gotcha** (2026-04-22, agentHostChatContribution.test.ts:MockAgentHostService) — TypeScript class fields are initialized **top-to-bottom**. If a field initializer references another field (e.g. `rootState = { ... onDidChange: this._rootStateOnDidChange.event ... }`), the referenced field **must be declared first** or you'll hit `Cannot read properties of undefined (reading 'event')` at runtime. In `MockAgentHostService` this means `_rootStateOnDidChange: Emitter<...>` must be declared before `rootState`. The TypeScript compiler does not warn about this.
- **gotcha** (2026-04-22, protocol/agentHostE2ETestHelpers.ts:startBackgroundApprovalLoop) — `client.waitForNotification(predicate, timeout)` does NOT consume notifications from its queue when the predicate matches; it only filters them. Any background loop that polls for an event class (e.g. `chat/toolCallReady`) and acts on it must dedupe by `getActionEnvelope(n).serverSeq` and skip already-handled seqs in *both* the predicate and the action guard, or it busy-spins on the same notification forever. Snapshot rounds avoid the analogous stale-match bug by capturing the notification backlog at round start.
- **gotcha** (2026-05-28, build/linux/debian/dep-lists.ts vs CI surfaces) — the deb auto-deps allowlist check (`vscode-linux-x64-prepare-deb` in `gulpfile.vscode.linux.ts`, error string "The dependencies list has changed.") only runs in the **Azure DevOps pipeline**, not in the GitHub Actions PR CI that gates merges. PR-level `gh pr checks` looks all-green even when this is about to fail, and the AzDo failure surfaces hours later. When bumping anything that ships a prebuilt native module (`@github/copilot`'s `runtime.node`, `@vscode/sqlite3`, `native-watchdog`, etc.), proactively diff GLIBC tiers — e.g. `objdump -T <module>.node | grep -oE 'GLIBC_[0-9.]+' | sort -u` against the previous version — and update `build/linux/debian/dep-lists.ts` in the same PR. The same blind spot applies to RPM (`build/linux/rpm/dep-lists.ts`), though RPM resolution rules are looser and usually already cover newer symbols. Also worth knowing: Azure DevOps build logs require organizational auth; `web_fetch` returns only the sign-in page, and `gh pr checks` shows the failing job name but not its log body — you have to either follow the link in a browser or ask whoever opened the PR to paste the failing chunk.
- **gotcha** (2026-04-22, protocol/copilotAgentHostE2E.integrationTest.ts) — when asserting on shell-command text the SDK emitted, anchor the regex with `^` and explicitly tolerate quoted variants (`cd "<dir>"` vs `cd <dir>`) and both chain operators (`&&` and `;`). A naked `String.includes("cd " + tempDir)` substring check misses quoted forms and is also tripped by tempDir appearing later in the same command.

## Changelog

- **2026-07-14** — 9380afea4c — replaced the obsolete gated real-SDK test description with the landed deterministic bundled-provider E2E architecture; documented strict LLM replay, executable multi-round AHP snapshots, semantic stream normalization, update modes, and removed obsolete gotchas for deleted real-SDK helper files. PR [#325892](https://github.com/microsoft/vscode/pull/325892).

- **2026-07-02** — f9f2fd558a — reconciliation: the four test layers still hold; added a **Mocked-LLM variant** callout under layer 3 for the new `copilotRealSdkMocked.integrationTest.ts` (`148a3b30735`), which runs the real Copilot SDK against a local mock LLM server and — unlike the `AGENT_HOST_REAL_SDK`-gated suites — is **not** gated, so it runs in default PR CI. Added `copilotCustomizations.integrationTest.ts` to the layer-2 file list and a new `src/vs/platform/agentHost/test/electron-browser/*.test.ts` location (renderer reverse-RPC/IPC channel registration, e.g. `localAgentHostService.test.ts`) to layer 1. The prior baseline SHA (`5edb399a83`, dated 2026-06-27) post-dates `09c18fe5c5` but is not an ancestor of `origin/main` because its source history was rebased/superseded before landing; this reconciliation therefore used the baseline-date fallback.

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
