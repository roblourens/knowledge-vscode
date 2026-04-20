# Agent Host Auto-Approve Picker

_Covers: src/vs/sessions/contrib/chat/browser/agentHost/agentHostPermissionPickerDelegate.ts, src/vs/sessions/contrib/chat/browser/agentHost/agentHostPermissionPickerActionItem.ts, src/vs/sessions/contrib/chat/browser/agentHost/agentHostSessionConfigPicker.ts, src/vs/sessions/contrib/copilotChatSessions/browser/permissionPicker.ts, src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts_

The auto-approve permission picker is the dropdown that lets a user pick `Default` / `Bypass Approvals` / `Autopilot` for a chat session. For agent-host sessions the level lives in AHP session-config under the well-known `autoApprove` property name. This doc covers how that one wire-level value plugs into the **two existing picker widgets** depending on where it renders, and how non-conforming agents fall back to the generic per-property picker.

## The two-widget split (and why we keep both)

There are two picker widgets in the tree, each scoped to one rendering context. They are intentionally separate — fully unifying them would force one of the two contexts to inherit styling/behavior that doesn't fit it.

| Widget | Location | Rendered in | Owner |
|---|---|---|---|
| `PermissionPicker` | `src/vs/sessions/contrib/copilotChatSessions/browser/permissionPicker.ts` | The Agents app's **new-chat page** (`Menus.NewSessionControl`) | Sessions layer |
| `PermissionPickerActionItem` | `src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts` | The running **chat input toolbar** (`MenuId.ChatInputSecondary`) — both VS Code chat and the Agents app's running session | Workbench layer |

Both widgets accept the **same delegate interface** (structurally compatible, defined separately in each layer with the matching field names `currentPermissionLevel`, `setPermissionLevel`, optional `isApplicable`). That means a single `AgentHostPermissionPickerDelegate` can drive both — which is what we do for agent-host sessions.

> **Why not collapse to one widget?** The two contexts have different sizing/spacing rules, different ancestor CSS chains (`.new-chat-in-session …` vs `.interactive-session .chat-secondary-toolbar …`), and the workbench widget already had `IStorageService`-backed warning suppression that the sessions widget doesn't need. The user explicitly accepted the duplication; the dedup that mattered was the **picker logic + delegate**, not the DOM.

## The delegate pattern

`IPermissionPickerDelegate` is the small bridge between either widget and the data backing it:

```ts
interface IPermissionPickerDelegate {
    readonly currentPermissionLevel?: IObservable<ChatPermissionLevel>;  // workbench: required
    readonly isApplicable?: IObservable<boolean>;                        // sessions only
    setPermissionLevel(level: ChatPermissionLevel): void;
}
```

- **`currentPermissionLevel`** — observable the widget reads from to render its label and check state. Optional on the sessions-layer interface (so the Copilot-CLI delegate can opt out and let the picker manage its own level via configuration defaults).
- **`isApplicable`** — observable the widget uses to hide itself when the picker shouldn't apply. Only on the sessions-layer interface; the workbench widget gets the same effect by toggling `this.element.style.display` from a subclass `autorun` (see below).
- **`setPermissionLevel(level)`** — write-back. Best-effort; failures are swallowed.

There are three concrete delegates today:

- `CopilotPermissionPickerDelegate` (sessions layer, in `permissionPicker.ts`) — for the Copilot-CLI new-chat page. Just a setter; the picker reads its own initial level from `chat.permissions.default` configuration.
- `AgentHostPermissionPickerDelegate` (`sessions/contrib/chat/browser/agentHost/agentHostPermissionPickerDelegate.ts`) — used by **both** widgets when the active session is an agent-host session. Backed by `provider.getSessionConfig(sessionId).values.autoApprove`, with reactivity wired through `provider.onDidChangeSessionConfig` and `sessionsManagementService.activeSession`.
- (workbench callers in chat input use the existing `PermissionPickerActionItem` directly with their own delegate logic — out of scope here.)

## The well-known `autoApprove` schema

Per [agent-host-topology](./agent-host-topology.md), property names in AHP session config are one of the two sanctioned VS Code-side conventions: **the protocol treats the bag as opaque; only the names are agreed**. `autoApprove` is the well-known name for the permission picker.

For VS Code to render the unified picker (with its built-in warning dialogs, autopilot gating, policy enforcement, and "Learn more about permissions" link), the agent must advertise `autoApprove` with this **shape**:

- `type: 'string'`
- `enum: string[]` containing at least `'default'`, all values being a subset of `{'default', 'autoApprove', 'autopilot'}` (`autopilot` is optional — agents may choose not to expose it)

`isWellKnownAutoApproveSchema(schema)` (exported from `agentHostPermissionPickerDelegate.ts`) is the predicate. Agents that advertise `autoApprove` with a *different* shape (extra enum values, different type) **do not** get the unified picker — they fall back to the generic per-property picker in `agentHostSessionConfigPicker.ts`. This is intentional: a hostile or legacy agent can't trick the unified picker into rendering against an unsupported schema, and a non-conforming agent isn't left with no UI at all.

The constant `AUTO_APPROVE_PROPERTY = 'autoApprove'` is the single source of truth for the property name and is exported from the delegate file.

## Wiring the two factories

`AgentHostSessionConfigPickerContribution` (in `agentHostSessionConfigPicker.ts`) registers two factories on `IActionViewItemService`:

- **`Menus.NewSessionControl` → `PermissionPicker`** with an `AgentHostPermissionPickerDelegate`. The picker renders into the new-chat slot and uses the delegate's `isApplicable` observable to hide itself reactively when the active session isn't agent-host or has a non-conforming schema.
- **`MenuId.ChatInputSecondary` → `AgentHostPermissionPickerActionItem`** (a thin subclass of `PermissionPickerActionItem`). The subclass owns its own delegate and calls `this.refresh()` from an `autorun` over `delegate.currentPermissionLevel` (the base class renders pull-style on demand). It also adds an `autorun` in `render()` that toggles `this.element.style.display` based on `delegate.isApplicable` — same reactive-hide pattern, different mechanism because the workbench widget doesn't expose the slot directly.

The generic per-property loop in `AgentHostSessionConfigPicker._renderConfigPickers` skips `autoApprove` only when its schema matches `isWellKnownAutoApproveSchema`. Otherwise it includes it, so non-conforming agents get a usable picker.

## Why the visibility check has to be reactive

Both widgets need to *react* to changes in the active session — the active session can change while the action view item is alive (e.g. user navigates back to the new-chat view from a running session). Two consequences:

- **`IActionViewItemService` factories run once per render**, not once per check. A one-shot "is this an agent-host session?" check at construction time would freeze the picker into whatever state it had when the menu first rendered. Both widgets thread the `isApplicable` observable through and call `display = visible ? '' : 'none'` in an `autorun`.
- **The base `PermissionPickerActionItem` renders its label pull-style** via `refresh()`. Subclasses that drive the level externally (like `AgentHostPermissionPickerActionItem`) must add an `autorun` over `delegate.currentPermissionLevel` to call `refresh()` themselves; the base doesn't subscribe.

## Tests

`src/vs/sessions/contrib/chat/test/browser/agentHost/agentHostPermissionPickerDelegate.test.ts` covers:

- `isWellKnownAutoApproveSchema` — exact match, missing `default`, extra enum values, wrong type.
- `currentPermissionLevel` — derives from active session's `autoApprove` value, falls back to `Default` when missing/unrecognized, updates on provider config-change.
- `setPermissionLevel` — routes to `provider.setSessionConfigValue`, no-op when no active session.
- `isApplicable` — reacts to active-session changes and to schema-shape changes.

The tests use a fake provider and exercise the delegate in isolation. The widgets themselves don't have direct unit coverage — both are exercised through the existing chat input integration tests.

## Where to edit

- A change to the well-known schema or the recognition predicate → `agentHost/agentHostPermissionPickerDelegate.ts` (and the test file).
- A change to **how either widget renders** (label, icon, dropdown contents, warning dialog, "Learn more" link) → the widget file itself. The two widgets diverged on purpose; consider whether a fix needs to land in both.
- A change to the menu wiring (which factory registers for which menu) → `agentHostSessionConfigPicker.ts`.
- The font/size/spacing of the new-chat-page picker → CSS rules under `.new-chat-in-session …` in `src/vs/sessions/contrib/chat/browser/media/newChatInSession.css`. The chat input toolbar's picker inherits the workbench `.chat-input-picker-item` styles; that's the right place for any toolbar-specific tweaks.
- Any change to `PermissionPickerActionItem`'s constructor signature (e.g. an added injected service) cascades to `AgentHostPermissionPickerActionItem`, which has to forward the new parameter explicitly to `super()`.

## Related

- [agent-host-topology](./agent-host-topology.md) — the "well-known property names" convention this picker hangs off of.
- [agent-host-sessions-providers](./agent-host-sessions-providers.md) — `IAgentHostSessionsProvider.getSessionConfig` / `setSessionConfigValue` / `onDidChangeSessionConfig`, which back the delegate.
- [agent-host-protocol](./agent-host-protocol.md) — `ISessionConfigPropertySchema` shape and the session-state subscription model.

## Debt & gotchas

- **gotcha** (2026-04-20, agentHostPermissionPickerActionItem.ts:constructor) — this subclass forwards every constructor parameter of `PermissionPickerActionItem` to `super()`. When the workbench base class gains a new injected service (it gained `IStorageService` once already), the subclass **must** be updated in lockstep — TypeScript will catch the missing argument, but only after the base class change merges. If you touch `PermissionPickerActionItem`'s constructor, search for subclasses before pushing.
- **gotcha** (2026-04-20, agentHostPermissionPickerDelegate.ts:isWellKnownAutoApproveSchema) — recognition is by enum *shape*, not by property name alone. An agent that advertises `autoApprove` with extra enum values (or a different `type`) deliberately falls back to the generic per-property picker. Don't relax the predicate to "only check that `default` is present" without weighing what new enum values would mean for the unified picker UI (which has no rendering path for unknown levels).
- **gotcha** (2026-04-20, agentHostPermissionPickerActionItem.ts:render + permissionPicker.ts:render) — `IActionViewItemService` factories run once per render, so any "should this picker be visible right now?" check that depends on dynamic state (active session, schema shape) **must** be wired through an observable + `autorun` that toggles `style.display`. Don't move the check into the factory body; the active session can change while the view item is alive.

## Changelog

- **2026-04-20** — `7f8e7e0f0c` — initial entry. Captures the two-widget split (`PermissionPicker` for `NewSessionControl`, `PermissionPickerActionItem` for `ChatInputSecondary`), the shared `AgentHostPermissionPickerDelegate`, the well-known `autoApprove` schema convention and recognition predicate, the fallback to the generic per-property picker for non-conforming agents, and the reactive-visibility pattern needed for action-view-item factories.
