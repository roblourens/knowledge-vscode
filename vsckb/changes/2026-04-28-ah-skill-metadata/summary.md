# Agent Host skill metadata fixes

**Date:** 2026-04-28
**VS Code branch:** roblou/agents/fix-local-agent-skill-naming-descriptions-2d13053f
**VS Code SHA at finalize:** 258af94280
**PR:** https://github.com/microsoft/vscode/pull/313077

## What was done

Fixed three related Agent Host skill-metadata bugs surfaced by the chat customization view, slash-command decorations, and `resolvePromptSlashCommand`:

1. **Local AH skills all named "SKILL".** `LocalAgentHostCustomizationItemProvider` was deriving the display name from the file basename, but skills live as `<name>/SKILL.md` so every skill came out as the literal string "SKILL". Switched to `IPromptsService.findAgentSkills`, which already parses frontmatter and returns the canonical name + description.
2. **Remote AH skills missing description.** `RemoteAgentCustomizationItemProvider` was getting the folder name correct but didn't expose the description. Added an on-demand `IFileService.readFile(SKILL.md)` + `new PromptFileParser().parse(...)` so name and description both come from frontmatter.
3. **Remote AH skill URI pointed at folder.** `ICustomizationItem.uri` for folder-style skills was the folder URI. Downstream `parseNew(item.uri)` in `resolvePromptSlashCommand` is a file read, so it threw `EntryIsADirectory` and chat input decorations / slash-command resolution silently broke. Now emits `<folder>/SKILL.md` and skips entries whose `SKILL.md` cannot be read.

Also added `supportsPromptAttachments: true` to both AH chat session contributions (local + remote) so prompt attachments wire up for AH sessions.

PR is draft, CI green after a follow-up test fix; awaiting merge.

## Key decisions

- **Did not unify the local and remote providers.** They look superficially similar but the data sources, lifecycles, change events, and item topology genuinely differ (local: `IPromptsService` index of local FS; remote: walks `agent-host://` URIs through `IFileService` per plugin folder, with a parent+children item shape and an expansion cache). Only the SKILL.md frontmatter parser is duplicated work — captured as debt rather than extracted now.
- **Remote skips unreadable SKILL.md entries** rather than emitting a known-broken folder URI. Caller-side defenses (try/catch in `resolvePromptSlashCommand`) would mask the underlying schema violation.
- **Decoration revival asymmetry left as debt, not fixed in this PR.** AH-restored chat requests come from raw AHP state without re-parsing, so slash-command decorations don't survive reload even when the skill is still recognized. The pragmatic fix is to re-run `ChatRequestParser.parseChatRequest` when hydrating AH user messages, but that's a separate change with its own surface area.

## What went wrong or was misunderstood

- **Initial assumption: filename was a fine source for skill name.** Wrong — folder-style skills are `<name>/SKILL.md`, so basename gives "SKILL" for everything. The convention isn't documented anywhere obvious; it lives implicitly in `findAgentSkills`. **Prevented by:** `agent-host-customizations.md` — body section "The skill-folder convention" plus explicit gotcha entry.
- **Initial assumption: emitting the folder URI for folder-style skills was fine.** Wrong — `ICustomizationItem.uri` flows into `parseNew(item.uri)` in `resolvePromptSlashCommand` and `InputEditorDecorations`, which is a file read. Directory URIs throw `EntryIsADirectory` and silently break decorations. The error only surfaced because the user reported decorations failing in the input editor. **Prevented by:** `agent-host-customizations.md` gotcha specifying the URI contract.
- **Forgot that an existing test exercised the folder-skill path when adding the "skip if unreadable" guard.** `provider hides synthetic bundle but still expands its contents` had no `readFile` mock for SKILL.md; the new guard then dropped the bundle's children. CI caught it. The lesson is that the synthetic in-memory test FS in this suite intentionally only mocks files referenced by name, so any code path that newly calls `readFile` on a folder-style skill needs a corresponding mock. **Prevented by:** the gotcha above (the URI contract implies SKILL.md is read), and by the fact that the test is now explicit about both happy-path and skip-path SKILL.md mocking.
- **Re-discovered the local-vs-remote asymmetry.** No knowledge doc covered the customization item providers — only `AgentHostSessionHandler` (which forwards customization *refs* over the wire) was documented. That's the pattern the new doc closes.
- **Did not catch the decoration-revival reload issue while writing the fixes.** The user noticed it after reloading. This was a separate path (chat session restore) from the one being fixed (provider output). **Prevented by:** `agent-host-customizations.md` body section "Decoration revival on reload" + cross-cutting debt entry in `index.md`'s Active debt & gotchas, so the next person touching either AH customizations or AH session restore knows the gap exists.

## What we learned

- The `<name>/SKILL.md` folder convention is load-bearing across at least three subsystems (local provider, remote provider, agent-host link rewrite) but is implied rather than declared anywhere central. Each subsystem reimplemented its own detection. A single `isSkillFile` / `getSkillFolderName` helper in `promptSyntax/` would have caught all three bugs with one fix.
- Local Electron VS Code on this Mac is broken (`TypeError: Cannot read properties of undefined (reading 'setPath')` from `scripts/test.sh`), so unit tests had to run in CI. This was slow but worked because the test added is purely model-level (no Electron).

## Doc updates

- **New:** `docs/agent-host-customizations.md` — covers both providers, the SKILL-folder convention, the URI contract, `supportsPromptAttachments`, and the decoration-revival asymmetry. Initial gotchas: SKILL.md URI contract, never-use-basename for skill name. Initial debts: duplicated SKILL.md frontmatter parsing in three places; AH chat decoration revival.
- **Updated:** `index.md` — added new doc to the Docs list and added a cross-cutting `## Active debt & gotchas` entry pointing at the AH chat decoration revival gap.
- **Not modified:** `docs/agent-host-session-handler.md` — already documents the SKILL.md client-side link-rewrite gotcha; the new doc cross-references it under `## Related`. No changelog entry was added there because the handler's behavior didn't change.
