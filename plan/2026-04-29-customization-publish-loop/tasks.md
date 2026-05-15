# Tasks: Stop the customization publish/echo treadmill

1. [ ] Short-circuit `SyncedCustomizationBundler.bundle()` when computed nonce equals `_lastNonce`; cache and return the previous `IBundleResult` without FS mutation.
   - file: `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/syncedCustomizationBundler.ts`
   - depends on: none
2. [ ] Add `customizationRefsEqual(a, b)` helper alongside `resolveCustomizationRefs`.
   - file: `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostLocalCustomizations.ts`
   - depends on: none
3. [ ] In `agentHostChatContribution.ts:_registerAgent`, construct the `customizations` observable with `customizationRefsEqual` as its equality comparator; wrap `Event.any(onDidChangeCustomAgents/SlashCommands/Skills/Instructions)` in `Event.debounce` (window 0).
   - file: `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts`
   - depends on: task #2
4. [ ] Apply the same observable comparator + `Event.debounce` change in the remote contribution.
   - file: `src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts`
   - depends on: task #2
5. [ ] Add a "second bundle with identical sources is a no-op" test in `syncedCustomizationBundler.test.ts`.
   - file: `src/vs/workbench/contrib/chat/test/browser/agentSessions/syncedCustomizationBundler.test.ts`
   - depends on: task #1
6. [ ] Add a dedupe regression test in `agentHostChatContribution.test.ts`: two consecutive identical `updateCustomizations()` runs result in a single `activeClientChanged` dispatch.
   - file: `src/vs/workbench/contrib/chat/test/browser/agentSessions/agentHostChatContribution.test.ts`
   - depends on: tasks #1, #2, #3
7. [ ] Manual repro per Verification step 3: replay the user's flow, confirm no `session/customizationsChanged` echoes during steady state.
   - depends on: tasks #1–#4
