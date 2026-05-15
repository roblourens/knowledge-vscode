# Tasks: System Notifications in AHP

1. [ ] Extend `types/state.ts` with `ResponsePartKind.SystemNotification`, `SystemNotificationResponsePart`, and structured `SystemNotificationKind` (first variant: `agentCompleted`); update the `ResponsePart` union. Acceptance: the provided Copilot async-agent completion event can be represented with renderable `content` plus structured metadata.
   - depends on: none
2. [ ] Confirm `types/actions.ts` and `types/reducers.ts` use the existing `session/responsePart` creation semantics for the new part. Acceptance: no new ephemeral `notify/*` and no new imperative command is introduced for replayable transcript content.
   - depends on: task #1
3. [ ] Update `types/version/v1.ts` with imports, aliases, and bidirectional compatibility assertions for the new state types. Acceptance: protocol typecheck catches incompatible future shape changes.
   - depends on: task #1
4. [ ] Add reducer fixtures under `types/test-cases/reducers/` (next free `NNN-` prefix). Acceptance: appending and completing a turn with a system notification is covered by `types/reducers.test.ts`.
   - depends on: task #2
5. [ ] Update `docs/guide/state-model.md`, `docs/guide/actions.md`, and `docs/specification/subscriptions.md`. Acceptance: docs explain the response-part model and why ephemeral protocol notifications are not the right shape.
   - depends on: task #2
6. [ ] Run `npm run generate` and `npm run test` in the protocol repo. Acceptance: generated surfaces, typecheck, lint, and tests pass.
   - depends on: tasks #3, #4, #5
7. [ ] Follow up in VS Code after protocol regeneration: map Copilot SDK `system.notification` live and replay events, render the new response part in the Agent Host session adapter. Acceptance: live, restored, local, and remote sessions show the notification in the same stream position.
   - depends on: task #6
