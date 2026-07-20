# Reorganize Agent Host integration tests

**Date:** 2026-07-19
**VS Code branch:** roblou/agents/agent-host-tests-analysis-organization
**VS Code SHA at finalize:** 73fe3a354d
**PR:** https://github.com/microsoft/vscode/pull/326531

## What was done

Agent Host tests were reorganized by what they actually exercise. Mock-agent AHP integration tests remain under `protocol/`; deterministic full-stack Claude, Codex, and Copilot tests now have a dedicated `e2e/` area with focused cross-provider suites, provider entrypoints, harness code, flat captures, AHP snapshots, and coverage; real-provider tests backed by a synthetic local LLM moved to `providerIntegration/`; and direct Copilot SDK import coverage moved to a clearly named node-level integration test.

The shared bundled-provider scenario matrix was split into core, file-operation, turn-lifecycle, workspace/isolation, and subagent modules without changing any test title or capture identity. Live non-deterministic Codex scenarios were separated from deterministic replay. The E2E coverage runner now measures only the real Agent Host plus bundled-provider stacks with replayed model traffic; mock-agent and synthetic-LLM tests do not contribute.

## Key decisions

- Treat deterministic bundled-provider tests as the prioritized E2E surface and organize it to support many future cross-provider scenarios.
- Classify tests by dependency boundary rather than by the fact that they all happen to use AHP or the integration-test runner.
- Preserve Martin's synthetic-LLM Copilot tests as provider integration coverage, while keeping them visibly separate from E2E and its coverage report.
- Keep fixture contents and all 144 test declarations unchanged; flatten only redundant artifact namespaces.
- Preserve the checked-in full-stack coverage baseline while renaming its artifact, avoiding unrelated native-V8 variance in an organizational change.

## What went wrong or was misunderstood

- The testing taxonomy classified `copilotCustomizations.integrationTest.ts` as a mock-agent protocol test even though it starts the real Copilot provider with a synthetic LLM, and it did not distinguish direct Copilot SDK tests that bypass Agent Host/AHP — **prevented by:** the corrected taxonomy, locations, and decision tree in `docs/testing.md`.

## What we learned

- The synthetic-LLM suites predated the capture/replay harness and were originally the tokenless path for exercising the real Copilot process. Their idle-release and customization coverage remains useful, but their model boundary and purpose differ from deterministic captured-provider E2E.
- Test count and titles can be verified mechanically across a large move; this reorganization preserved 144 test declarations, identical titles, and all 63 captures.
- Full-stack E2E coverage is a semantic boundary, not simply aggregate Agent Host process coverage: only real bundled providers with replayed real model traffic belong in that report.

## Doc updates

- Updated `docs/testing.md` with the current test taxonomy, directory layout, decision tree, coverage boundary, artifact paths, and corrected gotcha paths.
- Updated the testing entry in `index.md`.
- Removed the obsolete coverage gotcha that required aggregating mock-agent, protocol, and provider groups; no new debt or permanent gotcha was added.
