# Fix tool message markdown rendering in agent host

**Date:** 2026-04-18
**VS Code branch:** agents/fix-markdown-rendering-tools
**VS Code SHA at finalize:** ef2cdf49e1
**PR:** https://github.com/microsoft/vscode/pull/311201

## What was done

Five branches in `copilotToolDisplay.ts` were producing `invocationMessage` / `pastTenseMessage` values containing backtick-wrapped substrings (e.g. `` Searching for `foo` ``) but returning them as plain `string` rather than `{ markdown: ... }`. The chat UI's `StringOrMarkdown` handling treats plain strings as literal text, so the backticks rendered as visible characters instead of formatting the wrapped value as inline code.

Three coordinated fixes:

1. **Wrap with `md(...)`** so the message ships as `{ markdown: ... }`.
2. **Move the inline-code backticks outside the `localize(...)` call** so translators can't accidentally drop or transform them.
3. **Use `appendEscapedMarkdownInlineCode()`** to produce a safe inline-code span. Backslash-escaping backticks doesn't work in CommonMark inline code; the helper picks a fence longer than any backtick run in the content (and pads with spaces if needed). Promoted from a private `toMarkdownInlineCode` in `sendToTerminalTool.ts` into `vs/base/common/htmlContent`, and switched the terminal tool over to the shared utility.

Affected branches:

- `getInvocationMessage`: shell command, `Grep` (with pattern), `Glob` (with pattern)
- `getPastTenseMessage`: shell command, `Grep` (with pattern), `Glob` (with pattern)

The View/Edit/Create file paths were already correctly wrapping their outputs with `md(...)` and use `formatPathAsMarkdownLink()` (which produces `[name](uri)` from a URI, so doesn't have the same translator/escape risk for backticks).

## Key decisions

- **Fix at the producer, not the renderer.** The chat layer's behavior (plain string = literal) is the documented contract of `StringOrMarkdown`, and other producers rely on it.
- **Markdown punctuation outside `localize`.** Translators routinely modify punctuation; keeping `` ` `` (and brackets, in principle) outside the localized string makes the markup robust to translation.
- **CommonMark-correct inline-code escaping via a shared helper.** First attempt was a local `escapeMdInlineCode` that backslash-escaped backticks — that does NOT work in CommonMark inline code (you can't escape backticks inside a backtick span). Found an existing private implementation in the terminal tool, promoted it to `htmlContent.ts` next to `appendEscapedMarkdownCodeBlockFence`, and used the shared helper in both places.
- **Recorded as a single gotcha** capturing all three rules together, since they're load-bearing as a set when adding new tool branches.

## What we learned

- Several adjacent branches in `copilotToolDisplay.ts` were already using `md(...)`, so the wrapping pattern existed — these were just missed when the grep/glob branches were added. The full pattern (`md` + backticks-outside-localize + correct escape via shared helper) wasn't documented anywhere.
- **Don't reinvent markdown-escape logic.** Backslash-escaping backticks looks plausible but is wrong. When dealing with markdown construction, search for existing helpers in `htmlContent.ts` (and adjacent contributions) before writing new ones — there's already `escapeMarkdownSyntaxTokens`, `appendEscapedMarkdownCodeBlockFence`, and now `appendEscapedMarkdownInlineCode`.

### Init script bug fixed in passing

`scripts/init-session.sh` failed when the VS Code repo is itself a worktree: it tried to write `$VSCODE_REPO/.git/info/exclude` directly, but in a worktree `$VSCODE_REPO/.git` is a *file* (gitdir pointer), so `mkdir -p` on `.git/info` errored out. Fixed by resolving the shared gitdir via `git rev-parse --git-common-dir` (which is where `info/exclude` actually lives, and is shared across worktrees).

## Doc updates

- `docs/copilot-agent-provider.md` — extended `Covers:` to include `copilotToolDisplay.ts`; added a "Tool display messages" section covering the three rules; added a `gotcha` entry; added a new changelog line.
- `scripts/init-session.sh` — fixed the worktree-aware exclude-file write.
