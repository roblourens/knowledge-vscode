# Expand Agent Host multi-chat E2E coverage; document and harden the shared-host load ceiling

**Date:** 2026-07-22
**VS Code branch:** roblou/agents/document-e2e-coverage-process
**VS Code SHA at finalize:** 3896d0c770
**PR:** [#326829](https://github.com/microsoft/vscode/pull/326829)

## What was done
A bounded coverage-expansion round on the deterministic bundled-provider E2E suite, plus the infrastructure and documentation the round exposed as missing.

- Added ~42 shared multi-chat/peer-chat declarations (peer lifecycle, peer-local commands, workspace file tools, provider context isolation/resume/reset, and attachment projection), each with strict Claude + Copilot fixtures; Codex stays on the negative capability path. Coverage vs `main`: +1.15pp lines/statements, +2.80pp functions, +0.90pp branches.
- Added a checked-in `src/vs/platform/agentHost/test/node/e2e/KNOWN_ISSUES.md` — a categorized inventory (suspected product bugs, platform/replay limitations, record-only tests, expected capability skips) with reproduction commands and a reevaluation process, wired into the README, the `agent-host-e2e-tests` skill, and the private coverage-round skill so future rounds keep it current.
- Fixed a real harness bug: the permission test's confirm-until-complete loop re-matched a retained `chat/toolCallReady` notification and flooded the host with confirmations. Deduped by `serverSeq`.
- Diagnosed and fixed the underlying CI flake as a **shared-host load ceiling**: `AgentHostE2EServerLease` now proactively recycles the shared server every 25 tests and restarts on any failed test so a wedged host can't cascade into unrelated tests.
- Strengthened two context assertions (a Copilot review catch) so they can't pass vacuously when the prior assistant response is empty.

## Key decisions
- **Fix the harness, not the symptom.** The CI failure moved run-to-run (renames -> peer edits -> spaced-file -> permission -> planning-mode). Disabling whichever test happened to be at the tipping point was explicitly rejected in favor of bounding per-host load and isolating failures. No coverage was disabled to make CI green.
- **`MAX_TESTS_PER_SHARED_SERVER = 25`.** Well under the observed ~90+-turn wedge threshold while still amortizing host/SDK startup across the suite. Lower it (don't raise it) if a heavier suite drops the ceiling.
- **Symptoms, not root causes, in `KNOWN_ISSUES.md`.** Disabled variants stay behind the narrowest gate with an observed-symptom description and a repro command; root-cause hypotheses belong in an investigation/fix where they can be tested.
- **Provider-neutral oracles.** The strengthened context assertions require a *non-empty* prior response rather than a literal string, because Claude prepends an acknowledgement before `ready` where Copilot does not.

## What went wrong or was misunderstood
- **Claude's shared E2E process can lose its in-process `host` MCP server** when a test materializes both a default chat and a fresh peer after a long peer-lifecycle sequence; it passes in isolation and while recording, so focused replay never revealed it. Two full coverage runs failed and an unrelated subprocess-teardown fix was prototyped before the failure was minimized to the shared-suite ordering condition. **Prevented by:** the shared-server load-ceiling `gotcha:` on [testing](../../docs/testing.md#debt--gotchas) (recycle + restart-on-failure now covers this Claude-specific variant too) and the `KNOWN_ISSUES.md` process for gating a suspected bug behind a precise provider gate.
- **The shared replay host has a load ceiling that produces moving, CI-only failures.** One cached provider subprocess degrades past ~90+ model-backed turns and wedges a turn; the wedged host's mid-turn teardown cascades `ECONNREFUSED` into the next test, so the "failing test" moves run-to-run and won't reproduce on a healthy dev machine. Multiple red CI cycles were spent chasing the named test, and disabling individual tests only moved the tipping point. **Prevented by:** the shared-server lifecycle `gotcha:` on [testing](../../docs/testing.md#debt--gotchas) + the cross-cutting pointer in `index.md` (recognize a moving/cascading E2E failure as a shared-host lifecycle symptom, not a single-test bug; the lease now recycles + restarts).

## What we learned
- `waitForNotification` retains rather than consumes matched notifications, so *any* hand-rolled per-test approval loop (not just `startBackgroundApprovalLoop`) needs `serverSeq` dedup — recorded as its own concrete `gotcha:` alongside the load-ceiling one.
- A moving CI failure that a healthy dev machine can't reproduce is a strong signal for shared-fixture/host exhaustion rather than a defect in the test that happens to be red.
- Local reproduction of the ceiling requires stacking runs until the machine is loaded; a single fresh run has too much headroom to hit it.

## Doc updates
- **docs/testing.md** — body: added a "Shared-server lifecycle (the load ceiling)" paragraph and a pointer to the new `KNOWN_ISSUES.md` inventory + suspected-bug process. Debt & gotchas: added two `gotcha:` entries (shared-host load ceiling recycle/restart; permission-loop `serverSeq` dedup as a concrete `waitForNotification` recurrence). Added a 2026-07-22 changelog entry.
- **index.md** — added a cross-cutting "shared E2E host load ceiling" gotcha pointer under `## Active debt & gotchas`; refreshed the `testing` doc one-liner to mention `KNOWN_ISSUES.md` and the shared-server lifecycle.
