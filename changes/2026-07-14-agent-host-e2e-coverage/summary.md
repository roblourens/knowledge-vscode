# Add Agent Host E2E coverage and expand protocol scenarios

**Date:** 2026-07-19
**VS Code branch:** roblou/agents/e2e-agent-host-coverage-plan
**VS Code SHA at finalize:** 75098683e8
**PR:** [#326493](https://github.com/microsoft/vscode/pull/326493)

## What was done

The Agent Host test harness gained opt-in native V8 coverage collected from Agent Host child processes. A cross-platform runner retranspiles, runs deterministic resource, protocol, and bundled-provider groups in separate Electron invocations, waits for graceful server shutdown, and uses `c8` to emit text, HTML, LCOV, and JSON reports. A normalized loaded-files-only baseline is checked in for `src/vs/platform/agentHost/{common,node}`; it remains informational rather than a threshold gate.

Coverage-guided expansion added 50 protocol integration cases (40 resource operations, eight handshake/error cases, and two cursor errors) plus 15 shared bundled-provider scenarios backed by recorded LLM fixtures and AHP snapshots. The resource tests exposed and fixed missing-file writes, parent validation, conflict classification, dirty-write handling, serialized writes, and exclusive local `createOnly` writes. Replay now expands normalized workspace/temp placeholders into each test's current workspace before SSE serialization.

The new provider scenarios use a compact `behavior` AHP snapshot profile. Real tools still execute and direct filesystem/final-response assertions remain; snapshots retain tool identity, completion success/failure, detailed errors, assistant responses, and turn completion while excluding raw tool output, display strings, repeated ready/delta/confirmation traffic, usage, and incidental session updates. This made the same snapshots pass across Linux, macOS, and Windows without accepting incorrect side effects.

## Key decisions

- Use native `NODE_V8_COVERAGE` rather than instrumentation, and set it only on Agent Host child processes.
- Measure loaded executable Agent Host files only; do not penalize the baseline for modules the selected tests never load.
- Keep the baseline informational until a tolerance/ratchet policy is chosen.
- Run resource, protocol, and bundled-provider groups separately while aggregating one raw coverage directory.
- Reuse one replay server per provider suite, but reset both fixture and working directory per test and drain every turn before swapping fixtures.
- Keep exact protocol snapshots for permission/lifecycle tests and use behavior snapshots for scenarios whose primary oracle is real tool execution plus direct assertions.
- Preserve expected-behavior failures as targeted provider/OS skips instead of fixing unrelated product issues or blessing bad output.

## What went wrong or was misunderstood

- (none recorded)

## What we learned

- Native V8 aggregate coverage has small asynchronous range variance even when replay traffic is deterministic; future gating needs tolerance.
- Replay fixtures fake only the model boundary. Provider SDKs/CLIs and local tools still execute, so path placeholders must be expanded into the current workspace and shell/filesystem side effects remain meaningful.
- Provider-generated tool presentation is not a portable behavioral oracle. Cross-platform snapshots should preserve semantic lifecycle and direct side-effect assertions while omitting raw display/output noise.
- Codex currently duplicates response parts in the new scenarios, and some Copilot read/edit/delete turns do not complete. Those variants remain explicit skipped tests.
- Resource protocol failures should be classified with `toFileOperationResult`; provider error codes do not preserve the `IFileService` operation contract.

## Doc updates

- Updated `docs/testing.md` with coverage collection/reporting, replay workspace substitution, behavior-vs-protocol snapshot profiles, provider/platform gates, and three testing gotchas.
- Updated the testing entry in `index.md`.
- Added gotchas for split coverage invocations, native V8 variance, and preserving separate AHP snapshot profiles; removed no existing debt entries.
