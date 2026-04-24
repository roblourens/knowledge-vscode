# Tasks

- [ ] 1. Add `SessionMode` enum + `mode?: SessionMode` to `SessionSummary` in `agent-host-protocol/types/state.ts`.
- [ ] 2. Add `SessionModeChanged` to `ActionType` enum + `SessionModeChangedAction` interface in `agent-host-protocol/types/actions.ts`. Add to union.
- [ ] 3. Add reducer case in `agent-host-protocol/types/reducers.ts`.
- [ ] 4. Run `npx tsx scripts/sync-agent-host-protocol.ts` to regenerate `src/vs/platform/agentHost/common/state/protocol/`.
- [ ] 5. In `CopilotAgentSession`: subscribe to SDK `session.mode_changed` event, fire AHP `session/modeChanged` progress action.
- [ ] 6. In `CopilotAgentSession.initializeSession`: after wrapper created, call `session.rpc.mode.get()` and dispatch initial mode if non-default.
- [ ] 7. In `CopilotAgentSession`: add `setMode(mode)` calling `session.rpc.mode.set({ mode })`.
- [ ] 8. In `CopilotAgent` / `IAgent`: thread a `setMode` capability down to the session.
- [ ] 9. In `IAgentService` / `agentService.ts`: add `setSessionMode(uri, mode)` mirroring `setSessionModel`.
- [ ] 10. In workbench `agentHostSessionHandler.ts`: handle a chat request to switch mode (TBD — probably surface as a chat command later; for now just expose the service method).
- [ ] 11. Map `mode_changed` in `mapSessionEvents.ts` if needed for resume / history rebuild.
- [ ] 12. Add unit test for the reducer case in `agent-host-protocol/types/reducers.test.ts`.
- [ ] 13. Add Agent Host test for `CopilotAgentSession` mode flow.
- [ ] 14. Run typecheck task and fix any errors.
- [ ] 15. (Stretch) Plan file: subscribe to SDK `session.plan_changed`, call `rpc.plan.read()`, expose plan path via session artifact event.

## Discoveries for finalize

(populated as work progresses)
