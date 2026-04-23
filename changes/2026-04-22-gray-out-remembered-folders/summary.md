# Gray out remembered folders for offline agent hosts

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/gray-out-remembered-folders
**VS Code SHA at finalize:** 9b9ea27efc
**PR:** [#312063](https://github.com/microsoft/vscode/pull/312063)

## What was done

In the session workspace picker (`sessionWorkspacePicker.ts`), the agent host row for a disconnected remote host was already rendered as disabled/grayed-out. However, the remembered (previously used) folder rows beneath it were still rendered as fully enabled — a visual inconsistency where the host was grayed out but its folders were not.

Fixed by threading the provider's connection status through `_buildItems` and:
- Setting `disabled: true` on remembered-folder items only when the provider status is exactly `Disconnected` (not `Connecting`).
- Showing `(Offline)` in the group title for `Disconnected` providers.
- Showing `(Connecting)` in the group title for `Connecting` providers (folders remain enabled so the user can attempt to select one as the host reconnects).

Clicking a disabled folder was already a no-op via the existing `_isProviderUnavailable` guard at the selection handler — this change just aligns the visual state with that existing behaviour.

## Key decisions

- **Only gray out for `Disconnected`, not `Connecting`:** A connecting host may come online at any moment; disabling its folders during that brief window would be unnecessarily restrictive and confusing. `_isProviderUnavailable` lumps both states together, so we bypass it and check the exact `RemoteAgentHostConnectionStatus` value.
- **Distinct group labels per state:** `(Offline)` for disconnected, `(Connecting)` for still-connecting. This was prompted by a Copilot code-review comment on the PR noting that `(Offline)` was misleading for the connecting state.

## What went wrong or was misunderstood

- **Initial label choice was inaccurate:** `(Offline)` was reused from a nearby localized string, but `_isProviderUnavailable` covers both `Disconnected` and `Connecting`, making the label wrong for the connecting case. The reviewer caught it immediately. **Prevented by:** awareness that `_isProviderUnavailable` is a binary check that conflates two states — now noted in this summary. Future changes in this area should check the exact enum value when the two states require different UI treatment.

## What we learned

- The `_isProviderUnavailable` helper in `sessionWorkspacePicker.ts` is a coarse boolean that returns `true` for both `Disconnected` and `Connecting`. It's correct for "should selection be blocked?" but wrong for "should the item look broken?". When you need to distinguish the two states for UI purposes, read `provider.connectionStatus?.get()` directly and compare against `RemoteAgentHostConnectionStatus`.

## Doc updates

- No doc body changes — this was a purely cosmetic UI fix with no architectural implications.
