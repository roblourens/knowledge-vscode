# Plan: Re-parse AH-restored requests for slash decorations

When an AH chat session is restored (window reload, switching back to a session in the sessions list, etc.), the user request text is rehydrated from raw AHP state without running `ChatRequestParser`. The result is a single `ChatRequestTextPart` covering the whole prompt, so previously-decorated slash commands such as `/skill <name>` lose their pill on reload. This plan re-parses each restored request through `ChatRequestParser` **on the AH side only**, then carries the result through `IChatSessionHistoryItem` so `ChatService.loadRemoteSession` can use it without changing behavior for any other contributed-session provider.

## Knowledge context used

- [agent-host-customizations](../../docs/agent-host-customizations.md) — the "Decoration revival on reload" section names this exact bug and identifies the pragmatic fix. Also confirms both AH chat session contributions declare `supportsPromptAttachments: true`, which is what allows `/skill` to be parsed as a `ChatRequestSlashPromptPart` even with an agent in scope.
- [agent-host-session-handler](../../docs/agent-host-session-handler.md) — confirms `AgentHostSessionHandler` is the workbench-side adapter that owns AH-specific hydration via `turnsToHistory` and is the right place to enrich history items.
- [agent-host-topology](../../docs/agent-host-topology.md) — confirms `AgentHostSessionHandler` is shared across local and remote AH, so a single change here covers both deployment configurations.

## Approach

We're using **Option B**: AH owns the parsing, and the chat service consumes a pre-parsed value when present. This keeps blast radius scoped to AH-restored sessions; cloud and other contributed providers continue to take the existing `ChatRequestTextPart` fallback path.

Concretely:

1. **Extend `IChatSessionRequestHistoryItem`** in `src/vs/workbench/contrib/chat/common/chatSessionsService.ts` with an optional `parsedPrompt?: IParsedChatRequest`. Optional, additive, and consumed only by `loadRemoteSession`.
2. **Populate it in `AgentHostSessionHandler`.** The handler already calls `turnsToHistory` from `stateToProgressAdapter.ts`. We keep `turnsToHistory` pure and add a small post-pass in the handler that walks the produced request items and runs `ChatRequestParser.parseChatRequestWithReferences([], new Map(), item.prompt, ChatAgentLocation.Chat, { sessionType: this._config.sessionType, forcedAgent, attachmentCapabilities: forcedAgent?.capabilities })`. The handler already has DI; injecting `ChatRequestParser` is one constructor parameter.
   - We use `parseChatRequestWithReferences` (not `parseChatRequest`) so the current input box's dynamic variables and selected tools never bleed into historical messages.
   - `forcedAgent` comes from `this._chatAgentService.getAgent(this._config.sessionType)` — same lookup `loadRemoteSession` does today. If unresolved, parse without it (the `/skill` prompt-slash branch still fires in the no-agent case per `tryToParseSlashCommand`).
3. **Consume it in `ChatService.loadRemoteSession`.** Where today's history loop builds the single-`ChatRequestTextPart` `IParsedChatRequest`, prefer `message.parsedPrompt` if present. The existing fallback shape stays exactly as-is for everything else. There is a second nearly identical site for `onDidStartServerRequest` — see below.
4. **Server-initiated turns.** The other manual `IParsedChatRequest` site is in the `onDidStartServerRequest` callback in `chatServiceImpl.ts`; it receives just `{ prompt }`. To keep symmetry, extend the event payload to optionally carry `parsedPrompt?: IParsedChatRequest`, and have `AgentHostSessionHandler.startServerRequest` pre-parse before firing. Same gating: AH supplies it, no other provider does.

If the parser ever throws or returns no parts, the chat service falls back to today's `ChatRequestTextPart` shape.

## Steps

1. **Extend the type.** Add `parsedPrompt?: IParsedChatRequest` to the request branch of `IChatSessionHistoryItem` in `src/vs/workbench/contrib/chat/common/chatSessionsService.ts`. — *depends on: none*
2. **Wire `loadRemoteSession` to prefer `message.parsedPrompt`.** In `chatServiceImpl.ts`, when constructing `parsedRequest` in the history loop, use `message.parsedPrompt ?? <existing single-text-part shape>`. — *depends on: step 1*
3. **Inject `ChatRequestParser` into `AgentHostSessionHandler`** and add a small `parseHistoryPrompts(history)` post-pass after the existing `turnsToHistory(...)` call in `provideChatSessionContent` (around line 514). The pass mutates each request item to set `parsedPrompt`. Keep `turnsToHistory` pure (no parser dependency, no test changes). — *depends on: step 1*
4. **Server-initiated turn payload.** Extend `IChatSession.onDidStartServerRequest` payload with optional `parsedPrompt`, populate it in `AgentHostSessionHandler` where it calls `chatSession.startServerRequest(...)` (around line 873), and consume it in `chatServiceImpl.ts` `onDidStartServerRequest` handler. — *depends on: steps 1, 3 (uses same parser)*
5. **Smoke-test.** `/skill plan ...` to a local Copilot CLI AH session, reload, confirm pill restored. Repeat against a remote AH host. Confirm a non-AH cloud session restore is byte-identical to before (no new decorations). — *depends on: steps 2, 3, 4*

## Relevant files

- `src/vs/workbench/contrib/chat/common/chatSessionsService.ts` — add optional `parsedPrompt` to the request branch of `IChatSessionHistoryItem`; extend `onDidStartServerRequest` payload type.
- `src/vs/workbench/contrib/chat/common/chatService/chatServiceImpl.ts` — `loadRemoteSession`: history loop and `onDidStartServerRequest` handler. Use `message.parsedPrompt`/`event.parsedPrompt` if present; otherwise unchanged.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts` — inject `ChatRequestParser`, add the post-pass after `turnsToHistory`, and pre-parse before `chatSession.startServerRequest` (~line 873).
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/stateToProgressAdapter.ts` — `turnsToHistory` stays pure. No edits.
- `src/vs/workbench/contrib/chat/common/requestParser/chatRequestParser.ts` — `parseChatRequestWithReferences` is the entry point we use; confirms forced-agent + `supportsPromptAttachments: true` produces `ChatRequestSlashPromptPart` for `/skill`.
- `src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts` and `src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts` — for reference: both declare `supportsPromptAttachments: true`. No edits.

## Verification

1. Manual: in the agents window, send `/skill plan run a quick plan` to a Copilot CLI AH session. Confirm the `/skill` pill renders. Reload the window, reopen the session, and confirm the pill is still there.
2. Manual: same flow against a remote AH host (SSH or tunnel) — confirms the fix is connection-agnostic and works for both AH deployments.
3. Manual: regression check — open an existing non-AH contributed session (e.g. a cloud session) and confirm restore behavior is **byte-identical** to before this change (the new field is undefined for those providers, so the existing single-`ChatRequestTextPart` path is unchanged).
4. Unit: add a test in `src/vs/workbench/contrib/chat/test/browser/agentSessions/` (alongside `stateToProgressAdapter.test.ts`) that drives `AgentHostSessionHandler`'s post-pass with a mocked parser/agent service and asserts each request item ends up with a `parsedPrompt` whose parts include `ChatRequestSlashPromptPart` for a `/skill` message.

## Decisions

- **Option B (AH owns the parsing).** Scope-of-blast-radius decision: only AH-restored sessions get the new behavior. Cloud and other contributed providers are not touched because their `IChatSessionRequestHistoryItem.parsedPrompt` is undefined and `loadRemoteSession` falls through to today's `ChatRequestTextPart` shape.
- **Use `parseChatRequestWithReferences` with empty references**, not `parseChatRequest`. The latter pulls live dynamic variables and selected tools from the *current input box* — wrong for historical messages.
- **Keep `turnsToHistory` pure.** Don't push a `ChatRequestParser` dependency into a function that's currently a clean unit-test target. Run the parser as a separate post-pass inside `AgentHostSessionHandler`.
- **Cover server-initiated turns too.** Extending `onDidStartServerRequest`'s payload with optional `parsedPrompt` is small, symmetric, and means a queued message that flushes after reconnect also keeps its decoration. (Out-of-scope alternative: rely on the protocol replay landing the message as a regular history item.)
- **Out of scope**: persisting structured `IParsedChatRequest` parts in AHP state. AHP intentionally carries only `userMessage.text` (see `agent-host-protocol`), and re-parsing on the client is the right layer — it also retroactively picks up skills that became known after the request was originally sent.

## Risks and open questions

- **`IParsedChatRequest` is defined under `common/requestParser/`; `IChatSessionHistoryItem` lives in `common/chatSessionsService.ts`.** Both are in `common`, but adding the import expands what `chatSessionsService.ts` depends on. Verify no layer/eslint rule complains; if it does, we can either move the type or expose a thin alias from `chatSessionsService.ts`.
- **Agent may be unresolvable at the moment the handler runs the post-pass** (e.g. agent registration race during startup). When that happens we parse without `forcedAgent`/`attachmentCapabilities` — `tryToParseSlashCommand` still produces a `ChatRequestSlashPromptPart` in the no-agent branch for prompt commands, so we still recover the decoration. If anything goes wrong, the fallback yields today's behavior.
- **Type creep on `IChatSessionHistoryItem`.** Other providers may, over time, want to set `parsedPrompt` for the same reasons. That's fine — the field is additive and optional.

## Docs that will need updating

- [agent-host-customizations](../../docs/agent-host-customizations.md) — the "Decoration revival on reload" section currently describes the asymmetry as an open issue. After this lands, update it to: AH-restored requests are now re-parsed via `ChatRequestParser` in `loadRemoteSession`, so slash-prompt decorations survive reload (and retroactively pick up skills that became known after send). The corresponding `## Debt & gotchas` entry ("AH chat session restore path") should be removed.
- `index.md` — the matching `debt (AH chat decoration revival)` cross-cutting entry in `## Active debt & gotchas` should be removed.
