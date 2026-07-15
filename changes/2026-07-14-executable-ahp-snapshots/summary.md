# Add executable AHP snapshots to Agent Host E2E tests

**Date:** 2026-07-14
**VS Code branch:** roblou/agents/executable-ahp-snapshots
**VS Code SHA at finalize:** 9380afea4c
**PR:** [#325892](https://github.com/microsoft/vscode/pull/325892)

## What was done

The bundled-provider Agent Host E2E harness gained semantic AHP traffic snapshots alongside its existing LLM record/replay fixtures. An AHP snapshot is executable: each round provides `clientToServer` test input and `serverToClient` expected output, with a server message marking the synchronization boundary before the next round. The existing Copilot client-tool scenario was reduced from extensive imperative choreography and assertions to a one-line snapshot runner call while retaining support for focused assertions when relationships are clearer in code.

Snapshot projection normalizes volatile resources, turn ids, tool-call ids, timestamps, temporary directory suffixes, and provider streaming details. It coalesces `chat/responsePart` plus `chat/delta`, excludes environment-dependent customization/root-summary noise, and omits exact token counts while replaying stable positive usage values. Replay cache misses now surface directly at the scenario failure instead of appearing first as generic provider errors and again during teardown.

The harness supports tokenless AHP-only updates, LLM-only recording, and a single `AGENT_HOST_UPDATE_SNAPSHOTS=1` mode that records both boundaries in one run. Record-only abort tests remain excluded from combined updates.

## Key decisions

- Store AHP input and output together in ordered rounds rather than duplicate top-level YAML keys or separate files.
- Treat object fields as a curated semantic projection so additive protocol properties do not churn every fixture, while action sequence and selected behavior fields remain exact.
- Separate client-to-server and server-to-client ordering within each round, avoiding assertions on accidental cross-direction scheduling.
- Use semantic stream coalescing rather than changing the generic integration-test runner or running record/replay as two separate processes.
- Preserve snapshot `clientToServer` input during update mode and rewrite only observed `serverToClient` output.
- Keep exact LLM token counts out of fixtures because they are volatile metadata, not behavior under test.

## What went wrong or was misunderstood

- (none recorded)

## What we learned

- `TestProtocolClient.waitForNotification` searches the retained backlog; round synchronization must exclude every notification already present at round start, not only prior round-end markers.
- Live CAPI SSE and regenerated replay SSE can split text differently. AHP assertions must canonicalize response parts and deltas to final semantic content.
- A CAPI SDK error in replay may originate from the local strict replay proxy, not the real network. Surfacing the proxy's cache-miss error directly makes this distinction clear.
- Updating an entire provider file intentionally follows current provider defaults and can cause broad model/dialect fixture changes; `--grep` is the right scope for one scenario.

## Doc updates

- Updated `docs/testing.md` with the deterministic bundled-provider E2E architecture and removed obsolete gotchas for deleted `*RealSdk` helper files.
- Updated the testing entry in `index.md`.
- No new debt or gotcha entries were added from a proactive gap log; no session plan folder existed.
