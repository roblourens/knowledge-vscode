# Hide "Enter to Apply" tooltip in session workspace picker

**Date:** 2026-05-01
**VS Code branch:** roblou/agents/remove-enter-to-apply-tooltip
**VS Code SHA at finalize:** 862154f9e0
**PR:** https://github.com/microsoft/vscode/pull/313826

## What was done

Every row in the session workspace picker was showing an "Enter to Apply" tooltip. That tooltip comes from the shared `ActionList` renderer (`src/vs/platform/actionWidget/browser/actionList.ts`), which falls back to a `"{keybinding} to Apply"` title when an item has no explicit `tooltip` and no `hover`. The hint makes sense for code-action / lightbulb menus but is misleading anywhere else.

Added a new `IActionListOptions.hideDefaultKeybindingTooltip` flag. When set, `ActionItemRenderer` skips the default keybinding tooltip on items without an explicit tooltip/hover. Opted the session workspace picker into it.

## Key decisions

- Opt-in flag rather than changing the default. The "F2 to Apply" tooltip is still useful for the original code-action consumers, so existing behaviour is preserved.
- Threaded the flag through the existing `IActionListOptions` plumbing rather than introducing a new constructor parameter, so consumers don't need to know about `ActionItemRenderer`.

## What went wrong or was misunderstood

- Initially only set `hideDefaultKeybindingTooltip` on the flat presentation (via `_buildListOptions`) and missed that the tabbed presentation in `sessionWorkspacePicker.ts._showTabbedPicker` builds its own `listOptions` inline inside the `createActionList` callback. The fix didn't take effect for the tabbed picker; the user had to point it out. — **prevented by:** this summary (the file is not big enough to warrant a doc; the lesson is "when changing `listOptions` in `sessionWorkspacePicker.ts`, search for *every* call site that builds `listOptions` — there are at least two and they don't share a helper").

## What we learned

- The session workspace picker has two presentations (flat via `IActionWidgetService.show` and tabbed via `TabbedActionListWidget`) that each construct their own `IActionListOptions` independently. Future picker-wide configuration changes need to touch both.

## Doc updates

- None. The fix is small and there is no existing doc covering `sessionWorkspacePicker.ts` or the platform `ActionList` widget; creating one for a single tooltip flag would be premature.
