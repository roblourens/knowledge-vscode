# Strip redundant `cd` prefix in agent host shell tool calls

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/cleanup-bash-commands-plan
**VS Code SHA at finalize:** 357bfe70c9
**PR:** [#312019](https://github.com/microsoft/vscode/pull/312019)

## What was done

The Copilot model frequently prefixes shell tool calls with a redundant `cd <workingDirectory> && …` even though the SDK already runs the tool in that directory. The extension-host CLI integration hides this in the workbench via `presentationOverrides` on `IChatTerminalToolInvocationData`, but the agent host did no equivalent cleanup, so chat sessions backed by the agent host showed the noisy `cd` prefix verbatim.

This change strips the prefix at the **AHP boundary** (so every client — workbench chat UI, future remote clients — sees the simplified command, and the rendered text is consistent with what the user sees). The actual command sent to the SDK / executed in the PTY is left verbatim, so runtime semantics are unchanged.

A new helper module `src/vs/platform/agentHost/common/commandLineHelpers.ts` exports:

- `extractCdPrefix(commandLine, isPowerShell)` — bash + pwsh regex parse including quoted-directory variant and `Set-Location` / `cd /d` forms (mirrors the extension-host CLI's regex set).
- `stripRedundantCdPrefix(toolName, parameters, workingDirectory)` — policy wrapper that mutates `parameters.command` in place when the prefix matches the session working directory.

`stripRedundantCdPrefix` is called from the **three independent shell-command display paths**: history replay (`mapSessionEvents.ts`), live tool start (`copilotAgentSession.ts` `wrapper.onToolStart`), and permission requests (`copilotToolDisplay.ts` `getPermissionDisplay` for both `'shell'` and `'custom-tool'`).

## Key decisions

- **Rewrite at the AHP boundary, not via display overrides.** The workbench/extension uses `presentationOverrides` to keep raw and displayed forms separate. The agent host lacks that override channel in AHP, so we rewrite the actual `parameters.command` (display-only — the SDK already has and runs the original args). This keeps every client in sync with no override metadata to coordinate.
- **Mutate `parameters` in place rather than building a sibling display string.** In `copilotAgentSession.ts`, `_activeToolCalls` stores the parsed parameters object; `getPastTenseMessage` in `onToolComplete` reads that same object. Mutating in place makes the past-tense message automatically reflect the rewrite without threading an extra value through.
- **Keep the `cd /d` and `Set-Location` PowerShell variants and the quoted-directory variant.** The extension-host CLI already supports all of these; mirror them for parity.
- **Don't try to consolidate the regex with the workbench / extension copies in this change.** Three copies now exist; logged as debt instead.

## What went wrong or was misunderstood

The retrospective from this session, distilled. Each bullet pairs the mistake with what would have prevented it and where that prevention now lives:

- **Initially fixed only the history-replay path** (`mapSessionEvents.ts`). Submitted as "done", and the user pointed out that `mapSessionEvents` is invoked by `getMessages()` — the live tool-start events from `wrapper.onToolStart` and the permission-request display path bypass it entirely. The result: the rewrite worked correctly when reopening a session, but the noisy `cd` prefix still appeared during live execution and on the permission prompt. **Prevented by:** new `gotcha` on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) listing the three independent shell-command display paths. The new "Shell command display rewriting" section in the doc body also makes the contract explicit so the next "rewrite this command for display" task knows up-front to patch all three sites.

- **Used naive `fsPath` string comparison for path equality.** The fix passed locally on macOS and shipped that way. Windows CI then failed because `URI.file('/repo/project').fsPath` is `\repo\project` on Windows, but the model emits forward-slash `cd /repo/project && …`. The Copilot review caught the same issue independently. **Prevented by:** `gotcha` on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) prescribing `URI.file(...)` + `extUriBiasedIgnorePathCase.isEqual` (with trailing-separator trimming on both sides) for any path comparison that crosses model-emitted text and a session URI.

- **Tried to add a mock-based WebSocket integration test.** Spent time scaffolding before realizing the mock `IAgent` (`provider: 'mock'`) bypasses `CopilotAgentSession` entirely — the live `stripRedundantCdPrefix` path doesn't run at all for mock-agent sessions. Real-SDK tests are the only end-to-end coverage that actually exercises the live path on the wire. **Prevented by:** the existing `testing.md` already calls out that real-SDK tests cover SDK adapter code, but the mock-bypass implication wasn't explicit enough to short-circuit the dead end. Captured here in the summary; if this trips someone again it's worth a `gotcha` on `testing.md` saying "mock-agent integration tests cannot exercise `CopilotAgentSession` live paths — for those scenarios you need a real-SDK test."

- **Real-SDK assertion was initially a fragile substring `.includes("cd " + tempDir)` check.** Copilot review caught two problems: (1) it misses quoted variants (`cd "<dir>"`), and (2) `tempDir` can legitimately appear later in the same command line. Fixed to use an anchored regex (`^cd (?:"…"|…)\s*(?:&&|;)`) that tolerates both quoted forms and both chain operators. **Prevented by:** new `gotcha` on [testing.md](../../docs/testing.md#debt--gotchas) about anchoring real-SDK shell-command assertions.

- **Three copies of the `extractCdPrefix` regex now exist** (workbench `runInTerminalHelpers.ts`, extension `copilotCLITools.ts`, agent host `commandLineHelpers.ts`). Not a bug, but clear consolidation debt — the agent-host version is the most complete (quoted-dir + pwsh `Set-Location` / `cd /d`), the workbench one is missing the quoted variant. **Tracked as:** `debt` entry on [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas).

- **Recurring merge conflicts in the same `copilotToolDisplay.ts` hunk** — the file is a hot spot right now (multiple in-flight PRs touch the title text and the `invocationMessage` / `toolInput` arguments). Required two cycles of merge-resolve-and-push. Pure workflow noise, not a knowledge gap; noted here for completeness.

## What we learned

- The **session working directory** was already known to `CopilotAgentSession` (in `_workingDirectory`) but wasn't threaded into `mapSessionEvents` — that helper had been called with `sessionId, sdkSession, agentName` only. Adding an optional fourth parameter (`workingDirectory?: URI`) was a one-line change at each of the two `_createAgentSession` call sites in `copilotAgent.ts` (`createSession` + `_resumeSession`), both of which already had the URI in scope. The same `_workingDirectory` is what `getPermissionDisplay` consumes.
- **Validate-by-revert** kept paying dividends: for each of the three call sites, temporarily replacing the `stripRedundantCdPrefix` call with `if (false && stripRedundantCdPrefix(...))` made exactly the new positive-path tests fail and left negative-path tests green. Without that step it's easy to write a "passes both before and after" tautology test.
- The **Copilot review** caught both substantive review comments before Windows CI did — the path-comparison fix and the substring-vs-regex assertion were both flagged in the first review cycle. Worth treating those comments as load-bearing on this kind of cross-platform / cross-shape work.

## Doc updates

- [copilot-agent-provider.md](../../docs/copilot-agent-provider.md):
  - Added `commandLineHelpers.ts`, `mapSessionEvents.ts`, `copilotToolDisplay.test.ts`, `mapSessionEvents.test.ts`, `commandLineHelpers.test.ts` to `Covers:`.
  - New body section **"Shell command display rewriting (`commandLineHelpers.ts`)"** between Tool display messages and Debt & gotchas, documenting the helper API and the three call sites.
  - Added two `gotcha` entries (three-path coverage; `URI.file` + `extUriBiasedIgnorePathCase.isEqual` for path comparison).
  - Added one `debt` entry (three copies of `extractCdPrefix` regex).
  - Changelog entry for SHA `357bfe70c9`.

- [testing.md](../../docs/testing.md):
  - Added one `gotcha` entry (anchored regex for real-SDK shell-command assertions).
  - Changelog entry for SHA `357bfe70c9`.
