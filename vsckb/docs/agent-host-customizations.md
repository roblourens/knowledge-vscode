# Agent Host customization item providers

_Covers: src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostLocalCustomizations.ts, src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostChatContribution.ts, src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHostCustomizationHarness.ts, src/vs/sessions/contrib/remoteAgentHost/browser/remoteAgentHost.contribution.ts_

The agent-host customization item providers turn an agent host's set of plugin/customization references into the per-file (skill / agent / instructions / prompt) entries that show up in the chat customization view, in the chat input editor's slash-command decorations, and in `resolvePromptSlashCommand` calls. They live alongside (but are distinct from) `AgentHostSessionHandler`'s in-protocol `customization` action forwarding — the handler sends customization *refs* over the wire, while these providers expand a ref into individual user-visible items by reading filesystems.

There are two implementations, one per app:

| Concern | Local AH (`LocalAgentHostCustomizationItemProvider`) | Remote AH (`RemoteAgentCustomizationItemProvider`) |
|---|---|---|
| File source | Local `IPromptsService` index (workspace + user + extensions) | Walks `agent-host://` URIs through `IFileService` per plugin folder |
| Skill metadata | `IPromptsService.findAgentSkills(token)` (already parses + sanitizes + truncates frontmatter) | `IFileService.readFile(SKILL.md)` + `new PromptFileParser().parse(...)` on demand |
| Item shape | Flat list of files | Parent plugin item + expanded children, with `groupKey` for host vs client-synced |
| Change events | `IPromptsService.onDidChange*` | `IAgentConnection.rootState` + `SessionCustomizationsChanged` actions |
| Caching | None — live query each call | `_expansionCache: ResourceMap<{nonce, children}>`, invalidated by nonce change |

These look superficially similar but should **not** be unified — the data sources, lifecycles, change events, and item topology are genuinely different. The only piece that is duplicated and would be a reasonable extraction is the SKILL.md frontmatter helper (also independently reimplemented in `AgenticPromptsService.discoverBuiltinSkills`).

## The skill-folder convention

Skills are conventionally a folder named after the skill, containing a `SKILL.md` whose frontmatter holds the canonical `name` and `description`. Both providers must understand this convention, otherwise:

- **Bad name.** `getFriendlyName(basename(file.uri))` on a `SKILL.md` returns `"SKILL"` for every skill. Use the parsed frontmatter `name`, falling back to the parent folder name. (For local: get this from `findAgentSkills`. For remote: read `SKILL.md` and parse with `PromptFileParser`.)
- **Bad URI.** `ICustomizationItem.uri` for a folder-style skill must point at `<folder>/SKILL.md`, **not** the folder itself. Downstream `IChatCustomizationHarnessService.resolvePromptSlashCommand` and `InputEditorDecorations.updateAsyncInputEditorDecorations` call `parseNew(item.uri)`, which is a file read; passing a directory URI throws `EntryIsADirectory` and silently breaks decorations and slash-command resolution.

The remote provider additionally **skips folder-style skill entries whose `SKILL.md` cannot be read** rather than emitting a known-broken URI. The local provider doesn't need this guard because `findAgentSkills` already filters at index time.

## `supportsPromptAttachments`

Both AH chat session contributions (local `agentHostChatContribution.ts` and remote `remoteAgentHost.contribution.ts`) declare `supportsPromptAttachments: true` in their `capabilities` block so the chat input wires up prompt attachment UI for AH sessions. This is independent of the providers above but is in the same "make AH skill/prompt UX reach parity" surface area; if you add another AH chat session contribution, set this flag too.

## Decoration revival on reload

There is a known asymmetry in how chat request decorations (e.g. the skill pill on a sent request) survive a window reload:

- **Local chat sessions.** Requests are persisted as serialized `IParsedChatRequest` parts and revived structurally by `reviveParsedChatRequest`. Whatever parts (including `ChatRequestSlashPromptPart`) were written at send time are restored exactly. There is **no** re-parsing against the current slash-command set.
- **AH chat sessions.** Requests are reconstructed from raw AHP state — the user message text, with no preserved parsed-parts structure. Slash-command decorations are therefore lost across reload, even when the skill is still recognized.

If you need decorations to survive reload for AH sessions, the pragmatic fix is to re-run `ChatRequestParser.parseChatRequest` against the current slash commands when hydrating each AH user message. This would also retroactively pick up skills that became known after the request was originally sent.

## Related

- [agent-host-session-handler](./agent-host-session-handler.md) — the in-protocol customization-ref forwarding (different concern); also home of the SKILL.md client-side link-rewrite gotcha.
- [agent-host-topology](./agent-host-topology.md) — explains why customizations are opaque [Open Plugin](https://open-plugins.com/) refs at the AHP layer.

## Debt & gotchas

- **gotcha** (2026-04-28, agentHostLocalCustomizations.ts:provideChatSessionCustomizations + remoteAgentHostCustomizationHarness.ts:_collectFromTypeDir) — for folder-style skills, `ICustomizationItem.uri` MUST be `<folder>/SKILL.md`, not the folder URI. Downstream `parseNew(item.uri)` is a file read; a directory URI silently breaks slash-command resolution and chat input decorations. The remote provider skips skills whose `SKILL.md` cannot be read; the local provider relies on `IPromptsService.findAgentSkills` to filter.
- **gotcha** (2026-04-28, agentHostLocalCustomizations.ts + remoteAgentHostCustomizationHarness.ts) — for skill display name, NEVER use `basename(file.uri)` on a `SKILL.md` — it returns the literal string `"SKILL"`. Use the frontmatter `name` (via `findAgentSkills` for local, `PromptFileParser` for remote) and fall back to the parent folder name.
- **debt** (2026-04-28, multiple) — SKILL.md frontmatter parsing is now duplicated in three places: `IPromptsService.findAgentSkills`, `RemoteAgentCustomizationItemProvider._readSkillMetadata`, and `AgenticPromptsService.discoverBuiltinSkills`. A shared helper in `promptSyntax/` would consolidate them.
- **debt** (2026-04-28, AH chat session restore path) — AH-restored chat requests don't re-parse for slash commands, so skill decorations don't survive reload. Re-running `ChatRequestParser.parseChatRequest` when hydrating AH user messages from AHP state would fix this.

## Changelog

- **2026-04-28** — `258af94280` — initial entry. Captures the local vs remote split, the SKILL-folder convention (frontmatter for `name`/`description`, SKILL.md URI for `item.uri`, skip unreadable SKILL.md entries), the `supportsPromptAttachments: true` capability flag on both AH chat session contributions, and the decoration-revival asymmetry between locally-persisted and AH-restored chat requests.
