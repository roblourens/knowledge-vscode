# Expand Agent Host E2E coverage and document the workflow

**Date:** 2026-07-20
**VS Code branch:** roblou/agents/document-e2e-coverage-process
**VS Code SHA at finalize:** b1114451a0
**PR:** [#326720](https://github.com/microsoft/vscode/pull/326720)

## What was done

Two coverage-guided rounds added 33 shared deterministic bundled-provider E2E declarations (99 provider executions) for host input capabilities, workspace completions, local rename/bang commands, session flags/config/active clients, chat draft/no-op behavior, and terminal lifecycle/error paths. The loaded-file native V8 report moved from 68.64% to 69.92% lines/statements, 55.65% to 58.84% functions, and 61.81% to 62.35% branches.

Local-command tests gained semantic AHP snapshots: detailed protocol snapshots for rename and behavior-profile snapshots for bang-command lifecycle, with direct assertions retained for persisted titles, terminal output, confirmation semantics, and exit reporting. Snapshot selection guidance now distinguishes protocol transcripts, direct external/value assertions, and hybrid tests.

Host-owned tests now register through `hostOnlyTest(...)`, which applies the shared timeout and routes them to one strict `captures/empty.yaml` even during recording mode. This replaced 99 redundant per-provider/test empty captures without allowing missing model-backed fixtures to fall back silently.

A public coverage-expansion strategy was added to the E2E README on the local `roblou/agents/document-e2e-coverage-process` branch, and a private user skill was created at `~/.copilot/skills/agent-host-e2e-coverage-round/` for iterative local use.

## Key decisions

- Use coverage to discover valuable missing contracts, not to optimize line percentage mechanically; inspect exact LCOV ranges and existing lower-layer tests before selecting a bounded batch.
- Count shared declarations separately from provider executions and favor provider-independent host behavior over equivalent prompt variants.
- Keep model-backed fixtures title-derived and strict; make no-model traffic equally explicit with `hostOnlyTest(...)` and a shared strict empty fixture.
- Use AHP snapshots for multi-message ordering/routing/lifecycle, direct assertions for external effects and omitted request/result payloads, and both when both contracts matter.
- Treat every platform shell/provider as real: accumulate PTY chunks, assert stable semantics rather than presentation, and gate only genuinely unsupported provider/platform combinations.
- Keep the coverage-round operating procedure private while it is still being polished; publish only durable contributor-facing principles in the repository README.

## What went wrong or was misunderstood

- Snapshot mechanics were documented without a practical rule for choosing snapshot, direct, or hybrid oracles — **prevented by:** the oracle-selection body update and profile gotcha in `docs/testing.md`.
- Steering-message state was treated as a stable cross-provider snapshot, but providers may consume it immediately and mutation without an active turn can destabilize the provider — **prevented by:** the steering gotcha in `docs/testing.md`.
- A cleanup helper assumed `test(...)` returned a chainable Mocha object in every Electron runtime — **prevented by:** the test-registration gotcha in `docs/testing.md`.
- Terminal assertions assumed framed PTY data, stable shell titles, and universal command-detection/completion — **prevented by:** the terminal/shell gotcha and cross-platform workflow guidance in `docs/testing.md`.
- Git-backed config discovery was assumed to release its temporary repository on Windows when the session disposed — **prevented by:** the Windows filesystem-lock note in the terminal/shell gotcha and a targeted test gate.
- Missing fixtures could not safely mean zero model traffic, but the harness initially required one empty file per host-only test — **prevented by:** the `hostOnlyTest(...)` and shared-empty-fixture body update in `docs/testing.md`.

## What we learned

- A broad full-run failure can be secondary damage from a wedged shared provider process; rerun exact failures in a fresh process before changing unrelated tests.
- Full-stack value often comes from host-side AHP/persistence/tool behavior even when the model boundary is intentionally never crossed.
- Cross-platform CI is part of the E2E contract. A locally deterministic terminal or Git test can still encode unsupported Windows shell/ownership assumptions.
- Test helpers should centralize lifecycle rules (timeouts, cleanup, model-traffic declaration) without changing test titles, because titles are artifact identities.

## Doc updates

- Updated `docs/testing.md` with host-feature/state suite organization, `hostOnlyTest(...)`, shared strict empty replay, snapshot/direct/hybrid selection, coverage-round strategy, and test-registration/terminal/steering gotchas.
- Updated the testing entry in `index.md`.
- Added a public coverage-expansion strategy to the VS Code E2E README on a new local branch; no new VS Code PR was opened or pushed.
- Created the private user skill `agent-host-e2e-coverage-round`.
