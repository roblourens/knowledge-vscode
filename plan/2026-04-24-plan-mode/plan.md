# Plan: Plan-mode parity for Agent Host (mode + plan file)

## Goal

Bring the Agent Host to parity with the EH CLI for **agent-mode switching** (interactive / plan / autopilot) and **plan.md surfacing**, within the constraints of the public `@github/copilot-sdk` 0.2.2.

## SDK constraint (key blocker)

The public SDK does **not** expose `respondToExitPlanMode()` and the CLI server has **no `session.exitPlanMode.handle*` RPC** (verified by grepping `node_modules/@github/copilot/copilot-sdk/index.js` for all `session.*` RPC method names). Even SDK 0.3.0 lacks this surface. Subscribing to `exit_plan_mode.requested` from the public SDK would hang the CLI's pending request indefinitely.

**Therefore:** we do NOT subscribe to `exit_plan_mode.requested` in this change. We file a debt entry and revisit when the SDK exposes a response RPC.

## What we DO ship

1. **AHP `SessionMode` field** on `SessionSummary` with values `'interactive' | 'plan' | 'autopilot'`. Optional (older sessions / non-Copilot agents) — undefined means "unset / not applicable".
2. **AHP `SessionModeChangedAction`** for state transitions, mirroring `SessionModelChangedAction`.
3. **Wire into `CopilotAgentSession`**:
   - On session create/resume, call `session.rpc.mode.get()` and emit a `session/modeChanged` action with the result.
   - Subscribe to `session.mode_changed` events from the SDK and forward them as `session/modeChanged` actions.
   - Add a `setMode(mode)` method that calls `session.rpc.mode.set({ mode })` and lets the resulting `session.mode_changed` event flow back through the same path (single source of truth).
4. **Plumb through `IAgent` / `IAgentService`** so a workbench client can dispatch a "set mode" request (similar to `setModel`).
5. **Plan file surfacing** — call `session.rpc.plan.read()` lazily and expose the result via the existing `tool_content_changed` / file URI path so the workbench can show plan.md inline. Subscribe to `session.plan_changed` events to refresh.
   - Keep this read-only for v1: editing plan.md and syncing back is not in scope without `respondToExitPlanMode`.

## Knowledge context used

- [docs/agent-host-protocol.md](../../docs/agent-host-protocol.md) — generated protocol layer + reducer/action discipline.
- [docs/copilot-extension-host-cli.md](../../docs/copilot-extension-host-cli.md) — EH CLI parity reference, public-vs-private SDK gotcha.
- [docs/copilot-agent-provider.md](../../docs/copilot-agent-provider.md) — `CopilotAgent` / `CopilotAgentSession` surface.
- [changes/2026-04-21-copilot-cli-agent-host-gap-audit/summary.md](../../changes/2026-04-21-copilot-cli-agent-host-gap-audit/summary.md) §"P1: Plan mode exit handling" — the gap this addresses.

## Out of scope (for this session)

- Exit-plan-mode UX (blocked on SDK).
- plan.md editing / writeback.
- Any UI for choosing `autopilot_fleet`.
