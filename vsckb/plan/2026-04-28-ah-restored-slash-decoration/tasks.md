# Tasks: Re-parse AH-restored requests for slash decorations

1. [ ] Add optional `parsedPrompt?: IParsedChatRequest` to the request branch of `IChatSessionHistoryItem` in `src/vs/workbench/contrib/chat/common/chatSessionsService.ts`. Extend the `onDidStartServerRequest` payload type the same way (optional `parsedPrompt`).
   - depends on: none
2. [ ] In `ChatService.loadRemoteSession` (`src/vs/workbench/contrib/chat/common/chatService/chatServiceImpl.ts`), prefer `message.parsedPrompt` when constructing the `parsedRequest` for `model.addRequest`. Fall back to today's single-`ChatRequestTextPart` shape if undefined.
   - depends on: task 1
3. [ ] In the same file, prefer `event.parsedPrompt` in the `onDidStartServerRequest` handler with the same fallback.
   - depends on: task 1
4. [ ] In `AgentHostSessionHandler` (`src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts`), inject `ChatRequestParser`. After the `turnsToHistory(...)` call in `provideChatSessionContent` (~line 514), run a post-pass that for each request item resolves the AH agent via `IChatAgentService.getAgent(this._config.sessionType)` and sets `parsedPrompt = parser.parseChatRequestWithReferences([], new Map(), item.prompt, ChatAgentLocation.Chat, { sessionType: this._config.sessionType, forcedAgent: agent, attachmentCapabilities: agent?.capabilities })`. Wrap in try/catch; on failure, leave `parsedPrompt` undefined.
   - depends on: task 1
5. [ ] In the same handler, populate `parsedPrompt` on the `startServerRequest` payload (~line 873) using the same parser call before firing. `turnsToHistory` itself is unchanged.
   - depends on: tasks 1, 4
6. [ ] Add a unit test under `src/vs/workbench/contrib/chat/test/browser/agentSessions/` that exercises the handler post-pass: a request with text `/skill foo bar` ends up with `parsedPrompt.parts` containing a `ChatRequestSlashPromptPart`, given a mocked agent with `supportsPromptAttachments: true` and a registered prompt slash command.
   - depends on: task 4
7. [ ] Manual verification: send `/skill plan ...` to a local Copilot CLI AH session, reload the window, confirm the `/skill` pill is restored. Repeat for a remote AH host (SSH or tunnel).
   - depends on: tasks 2, 3, 4, 5
8. [ ] Regression check: open an existing non-AH contributed session (cloud), reload, confirm restore behavior is unchanged (no `parsedPrompt`, no new decorations, no broken existing decorations).
   - depends on: tasks 2, 3
