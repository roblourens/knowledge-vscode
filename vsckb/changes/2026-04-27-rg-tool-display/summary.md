# Render Copilot CLI rg search tool with search icon

**Date:** 2026-05-02
**VS Code branch:** roblou/agents/rg-tool-rendering-update
**VS Code SHA at finalize:** d7edc11461
**PR:** [#313838](https://github.com/microsoft/vscode/pull/313838)

## What was done

Added first-class display for the Copilot CLI `rg` search tool in the VS Code agent host, alongside the existing `grep` tool. Both tools now show `Searching for {pattern}` / `Searched for {pattern}` messages with a search icon in the workbench chat UI.

The implementation uses separate typed interfaces (`ICopilotGrepToolArgs`, `ICopilotRgToolArgs`) per tool, a `SEARCH_TOOL_NAMES` set, a new `'search'` toolKind, and a new `IChatSearchToolInvocationData { kind: 'search' }` value in the `toolSpecificData` discriminated union. The search icon flows through `stateToProgressAdapter.ts` to `chatThinkingContentPart.ts`, which renders it as the outer "type" icon on the tool row — the same architecture terminal tools use.

## Key decisions

- **Separate interfaces per tool, not a merged "search family".** `ICopilotGrepToolArgs` and `ICopilotRgToolArgs` have identical fields today but are kept separate so they can diverge as the SDK evolves. The user explicitly pushed back on a merged interface.
- **toolSpecificData.kind over string-matching on toolId.** An earlier approach called `getToolInvocationIcon(toolId)` (which matches substrings like `'grep'` in the tool name) from the render layer. The user reversed this: "better to pass around the tool-specific data rather than hardcode copilot tool IDs at the rendering level." The `toolSpecificData.kind = 'search'` pipeline carries the semantic in typed AHP state.
- **Minimal display messages.** Just `Searching for {pattern}` — no filter flags, glob, or mode. Deliberate house style: readable rather than exhaustive.

## What went wrong or was misunderstood

- **Merged interface for grep and rg** — initially combined both into one interface. User corrected: keep one interface per real SDK tool, even when schemas match today. — **prevented by:** gotcha on `copilot-sdk-tool-display` doc (added this session).
- **Used string-matching icon approach first** — implemented `getToolInvocationIcon(toolId)` route because the EH CLI already does this. User reversed the decision after review. The EH CLI's pattern exists because it can't carry `toolSpecificData`; Agent Host can and should. — **prevented by:** the "Search tool icon via toolSpecificData" section now in the doc.
- **Double-icon bug** — after the revert and re-implementation, the tool row showed two icons: a generic tools icon (outer) plus the search icon (inner). Root cause: didn't understand that `chatThinkingContentPart.ts` renders an outer "type" icon and `ChatProgressSubPart`/`getIcon()` renders an inner "status" icon simultaneously. Setting `getIcon()` to return `Codicon.search` only handled the inner layer; the outer layer still fell through to `Codicon.tools`. Terminal tools handle this correctly with the `isTerminalTool` branch in `chatThinkingContentPart.ts` — search tools needed the same. — **prevented by:** the two-layer icon gotcha added to the doc this session.

## What we learned

- The `toolSpecificData` discriminated union is the right place to carry tool-type semantics for icon/rendering decisions. Adding a new kind requires touching: `chatService.ts` (union definition), `chatToolInvocation.ts`, `languageModelToolsService.ts`, `stateToProgressAdapter.ts` (set it), `chatThinkingContentPart.ts` (outer icon), and optionally `chatResponseAccessibleView.ts` (type alias).
- The chat tool row architecture has two visually separate icon elements. This is intentional: outer shows "what tool is this", inner shows "did it succeed". A new `toolSpecificData.kind` should drive only the outer icon.

## Doc updates

- `docs/copilot-sdk-tool-display.md`: added "Search tools (grep and rg)" section (separate interfaces, SEARCH_TOOL_NAMES, minimal message style); added "Search tool icon via toolSpecificData" section (full pipeline + why not getToolInvocationIcon); updated `Covers:` line to include stateToProgressAdapter.ts and chatThinkingContentPart.ts; added two gotchas: separate-per-tool-interface rule, two-layer outer/inner icon architecture.
- `plan/2026-04-27-rg-tool-display/` deleted.
