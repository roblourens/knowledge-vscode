# Copilot Agent Provider

_Covers: src/vs/platform/agentHost/node/copilot/copilotAgent.ts, src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts, src/vs/platform/agentHost/test/node/copilotAgent.test.ts_

`CopilotAgent` is the local Agent Host provider backed by the Copilot SDK. It is provider-specific code under `src/vs/platform/agentHost/node/copilot/`, below the generic AHP server layer and above the SDK runtime. Generic aggregation (`AgentService`) and UI consumers should receive already-filtered Copilot session metadata from this provider.

## Responsibilities

`CopilotAgent` owns:

- Starting and stopping the SDK `CopilotClient`, including the clean subprocess environment used for the CLI server.
- Advertising Copilot models and protected resources.
- Creating, forking, resuming, listing, disposing, aborting, truncating, and changing model selection for Copilot sessions.
- Building SDK session config from active client tools, customizations, hooks, MCP servers, custom agents, skills, and shell tools.
- Persisting provider-local metadata in the per-session Agent Host database.

It does not own AHP state shape or workbench rendering. Contract changes belong in [agent-host-protocol](./agent-host-protocol.md); turn execution and rendering belong in [agent-host-session-handler](./agent-host-session-handler.md).

## Session Ownership

The Copilot SDK can list sessions that were created outside VS Code's Agent Host, such as sessions from other Copilot CLI agents. `CopilotAgent.listSessions()` is responsible for filtering SDK results down to sessions that VS Code Agent Host owns or has already adopted.

The ownership signal is the existence of a per-session Agent Host database. `listSessions()` constructs the canonical `AgentSession.uri('copilot', sessionId)` for each SDK result and calls `ISessionDataService.tryOpenDatabase()`. If no database exists, the SDK session is skipped. This check must happen before project resolution or any metadata write so listing does not create databases for unrelated SDK sessions.

Any existing per-session database qualifies as owned. This intentionally keeps the rule simple: sessions created by Agent Host already create a database when metadata is stored, and older sessions with database metadata continue to appear. The implementation does not persist a separate Copilot ownership marker.

After a session passes the database gate, `listSessions()` may resolve project metadata and store the resolution to avoid rediscovering git context on later lists. That write is safe because the database already existed before the list operation considered the session owned.

## Metadata

Copilot provider metadata is stored in the session database's `session_metadata` table. Current keys include:

- `copilot.model` — serialized `IModelSelection`, including model config such as reasoning effort.
- `copilot.workingDirectory` — URI string for the session working directory.
- `copilot.project.resolved` — marker that project resolution was attempted.
- `copilot.project.uri` and `copilot.project.displayName` — cached project identity for list metadata.

Use `tryOpenDatabase()` for read-only checks that must not create session data. Use `openDatabase()` only on paths that intentionally create or update Agent Host-owned session data.

## Testing Pattern

Focused tests live in `copilotAgent.test.ts`. The SDK client is injected through a narrow protected factory seam because the SDK `CopilotClient` type has private members, which prevents lightweight structural fakes from being assigned to the class type directly.

For database-sensitive behavior, prefer real in-memory `SessionDatabase(':memory:')` instances where possible. The Copilot provider tests keep a small fake `ISessionDataService` only to control which session IDs have an existing database; the database implementation itself is real. This lets tests assert both the positive path (stored metadata is read) and the negative path (`listSessions()` does not call `openDatabase()` for unowned SDK sessions).

## Tool display messages

`copilotToolDisplay.ts` produces the generic display fields (`displayName`, `invocationMessage`, `pastTenseMessage`, `confirmationTitle`) that flow through AHP as `StringOrMarkdown`. Plain strings are rendered as **literal text** by the chat UI — so any message containing markdown syntax (backticks for inline code, `[text](uri)` links, etc.) MUST be wrapped with the local `md()` helper so it ships as `{ markdown: ... }`. A bare string with backticks renders the backticks as visible characters.

Two rules when interpolating a runtime value into an inline-code span:

1. **Keep markdown punctuation out of the localized string.** Put the backticks (or other markdown formatting) around the `{0}` placeholder *outside* the `localize(...)` call — translators can accidentally drop or transform punctuation, which silently breaks the markdown.
2. **Use `appendEscapedMarkdownInlineCode()` from `vs/base/common/htmlContent`** to wrap user-controlled values. Backticks inside an inline code span can't be backslash-escaped per CommonMark; the helper picks a fence of backticks longer than any run in the content (and pads with spaces when needed).

So the canonical pattern is:

```ts
md(localize('key', "Searching for {0}", appendEscapedMarkdownInlineCode(truncate(args.pattern, 80))))
```

For markdown file links, `formatPathAsMarkdownLink()` already produces the `[name](uri)` form — those still go through `md(...)`.

## Debt & gotchas

- **gotcha** (2026-04-18, copilotToolDisplay.ts:getInvocationMessage/getPastTenseMessage) — display messages with markdown formatting must (a) be wrapped with `md(...)` so they ship as `{ markdown: ... }`, (b) keep the markdown punctuation (backticks, brackets) *outside* the `localize(...)` call so translators can't break it, and (c) wrap interpolated user-controlled strings with `appendEscapedMarkdownInlineCode` for inline-code spans (backslash-escaping backticks does NOT work in CommonMark inline code). A plain `string` return from a `StringOrMarkdown`-typed function renders as literal text.

## Related

- [agent-host-topology](./agent-host-topology.md) — where provider-level listing work fits in the Agent Host architecture.
- [agent-host-protocol](./agent-host-protocol.md) — why this behavior is provider persistence, not a protocol change.
- [agent-host-session-handler](./agent-host-session-handler.md) — downstream turn and chat integration after a session is selected.

## Changelog

- **2026-04-17** — `9364e338cc` — initial entry documenting CopilotAgent SDK session filtering, database-backed ownership, metadata keys, and focused test seams.
- **2026-04-18** — `ef2cdf49e1` — added `copilotToolDisplay.ts` to Covers; documented the `md()` wrapping requirement, the keep-markdown-out-of-localize rule, and the `appendEscapedMarkdownInlineCode` helper for `StringOrMarkdown` display fields, with a gotcha entry covering all three.