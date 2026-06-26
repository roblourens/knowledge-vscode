# Agent Host Auto-Approve Picker

_Covers: src/vs/sessions/contrib/providers/agentHost/browser/agentHostPermissionPickerDelegate.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostPermissionPickerActionItem.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostSessionConfigPicker.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostModePicker.ts, src/vs/sessions/contrib/providers/agentHost/browser/agentHostClaudePermissionModePicker.ts, src/vs/sessions/contrib/providers/copilotChatSessions/browser/permissionPicker.ts, src/vs/sessions/contrib/providers/copilotChatSessions/browser/mobilePermissionPicker.ts, src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts_

The auto-approve permission picker is the dropdown that lets a user pick `Default` / `Bypass Approvals` / `Autopilot` for a chat session. For agent-host sessions the level lives in AHP session-config under the well-known `autoApprove` property name. The adjacent Agent Host mode picker handles the separate well-known `mode` property (`interactive` / plan-style modes) with its own UI, while Claude Agent Host sessions expose a distinct well-known `permissionMode` enum. This doc covers how those picker surfaces split across new-session and running-session UI, how dedicated pickers avoid or intentionally reuse the generic per-property fallback, and how non-conforming agents still get generic session-config controls.

## The two-widget split (and why we keep both)

There are two picker contexts in the tree, each scoped to one rendering surface. They are intentionally separate — fully unifying them would force one of the two contexts to inherit styling/behavior that doesn't fit it. The new-chat context now uses a mobile-aware wrapper on web, but it is still the sessions-layer picker shape driven by the same delegate.

| Widget | Location | Rendered in | Owner |
|---|---|---|---|
| `PermissionPicker` / `MobilePermissionPicker` | `src/vs/sessions/contrib/providers/copilotChatSessions/browser/permissionPicker.ts`, `mobilePermissionPicker.ts` | The Agents app's **new-chat page** (`Menus.NewSessionControl`) | Sessions layer |
| `PermissionPickerActionItem` | `src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts` | The running **chat input toolbar** (`MenuId.ChatInputSecondary`) — both VS Code chat and the Agents app's running session | Workbench layer |

Both widgets accept delegate interfaces that are **structurally compatible for the shared permission-level fields** (defined separately in each layer with the matching field names `currentPermissionLevel`, `setPermissionLevel`, optional `isApplicable`). That means a single `AgentHostPermissionPickerDelegate` can drive both — which is what we do for agent-host sessions. The workbench `PermissionPickerActionItem` also has optional extension-contributed permission callbacks (`getExtensionPermissions` / `setExtensionPermission`) used by other chat providers; the agent-host delegate intentionally does not implement those because its contract is the well-known AHP `autoApprove` value.

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

- **`currentPermissionLevel`** — observable the widget reads from to render its label and check state. Optional on the sessions-layer interface (so the Copilot-CLI delegate can opt out and let the picker manage its own level via configuration defaults). `MobilePermissionPicker` uses the same delegate; only its popup presentation changes.
- **`isApplicable`** — observable the widget uses to hide itself when the picker shouldn't apply. Only on the sessions-layer interface; the workbench widget gets the same effect by toggling `this.element.style.display` from a subclass `autorun` (see below).
- **`setPermissionLevel(level)`** — write-back. Best-effort; failures are swallowed.

There are three concrete delegates today:

- `CopilotPermissionPickerDelegate` (sessions layer, in `permissionPicker.ts`) — for the Copilot-CLI new-chat page. Just a setter; the picker reads its own initial level from `chat.permissions.default` configuration.
- `AgentHostPermissionPickerDelegate` (`sessions/contrib/chat/browser/agentHost/agentHostPermissionPickerDelegate.ts`) — used by **both** widgets when the active session is an agent-host session. Backed by `provider.getSessionConfig(sessionId).values.autoApprove`, with reactivity wired through `provider.onDidChangeSessionConfig` and `sessionsManagementService.activeSession`.
- Workbench callers in chat input use the existing `PermissionPickerActionItem` directly with their own delegate logic, including optional extension-contributed permission groups — out of scope here except that constructor/delegate-shape changes can still affect `AgentHostPermissionPickerActionItem`.

## The well-known `autoApprove` schema

Per [agent-host-topology](./agent-host-topology.md), property names in AHP session config are one of the two sanctioned VS Code-side conventions: **the protocol treats the bag as opaque; only the names are agreed**. `autoApprove` is the well-known name for the permission picker.

For VS Code to render the unified picker (with its built-in warning dialogs, autopilot gating, policy enforcement, and "Learn more about permissions" link), the agent must advertise `autoApprove` with this **shape**:

- `type: 'string'`
- `enum: string[]` containing at least `'default'`, all values being a subset of `KNOWN_AUTO_APPROVE_VALUES` (`{'default', 'autoApprove', 'autopilot'}`).

`isWellKnownAutoApproveSchema(schema)` (exported from `agentHostPermissionPickerDelegate.ts`) is the predicate; it imports the value set `KNOWN_AUTO_APPROVE_VALUES` and the property name `SessionConfigKey.AutoApprove` from `src/vs/platform/agentHost/common/sessionConfigKeys.ts` — the platform-side source of truth for well-known config keys (`AutoApprove`, `Permissions`, `Isolation`, `Branch`, `BranchNameHint`). Agents that advertise `autoApprove` with a *different* shape (extra enum values, different type) **do not** get the unified picker — they fall back to the generic per-property picker in `agentHostSessionConfigPicker.ts`. This is intentional: a hostile or legacy agent can't trick the unified picker into rendering against an unsupported schema, and a non-conforming agent isn't left with no UI at all.

The property name itself is `SessionConfigKey.AutoApprove` (`'autoApprove'`); there is no longer a separate `AUTO_APPROVE_PROPERTY` constant in the delegate — the platform-side enum is the single source of truth, and the delegate is now a consumer of it. The same platform-side enum also contains `SessionConfigKey.Mode` (`'mode'`) for the dedicated Agent Host mode picker; do not model mode as another auto-approve enum value.

> Note: `SessionConfigPropertySchema` is no longer string-enum-only — the protocol now expresses `string` / `number` / `boolean` / `array` / `object` schemas with `items` / `properties` / `required`. The recognition predicate still narrows to the string-enum case because that's what the unified picker UI knows how to render; everything else flows into the generic per-property picker.

## Wiring the two factories

`AgentHostSessionConfigPickerContribution` (in `agentHostSessionConfigPicker.ts`) registers two factories on `IActionViewItemService`:

- **`Menus.NewSessionControl` → `MobilePermissionPicker`** with an `AgentHostPermissionPickerDelegate`. On phone-layout web it opens a bottom sheet; on wider viewports it falls through to the sessions-layer desktop picker behavior. The picker renders into the new-chat slot and uses the delegate's `isApplicable` observable to hide itself reactively when the active session isn't agent-host or has a non-conforming schema.
- **`MenuId.ChatInputSecondary` → `AgentHostPermissionPickerActionItem`** (a thin subclass of `PermissionPickerActionItem`). The subclass owns its own delegate and calls `this.refresh()` from an `autorun` over `delegate.currentPermissionLevel` (the base class renders pull-style on demand). It also adds an `autorun` in `render()` that toggles the outer render `container.style.display` based on `delegate.isApplicable`. Hiding only `this.element` leaves the enclosing `.chat-input-picker-item` action item alive, so its toolbar min-width still reserves an empty gap.

The generic per-property loop in `AgentHostSessionConfigPicker._renderConfigPickers` skips `autoApprove` only when its schema matches `isWellKnownAutoApproveSchema`. Otherwise it includes it, so non-conforming agents get a usable picker.

`AgentHostSessionConfigPicker` also recognizes a well-known `mode` property through `isWellKnownModeSchema(schema)`: a string enum containing at least `interactive`. When that predicate matches, the generic per-property loop skips `mode` and the dedicated `AgentHostModePicker` owns the UI. This keeps execution mode (interactive / planning-style behavior) visually and semantically separate from the permission level (`default` / `autoApprove` / `autopilot`).

Claude Agent Host sessions add a related but intentionally different case: well-known `permissionMode` is recognized by `isWellKnownClaudePermissionModeSchema(schema)`, and **running** sessions get a dedicated `AgentHostClaudePermissionModePicker` in `MenuId.ChatInputSecondary`. **New** sessions do not get a dedicated left-lane action in `Menus.NewSessionControl`; they deliberately fall through to the existing generic config chip in `Menus.NewSessionRepositoryConfig`, which keeps the permission chip next to repository/session config controls on the right side of the new-chat row. Moving the new-session Claude picker into `NewSessionControl` makes it look like a control-lane action and produces the wrong toolbar grouping.

`AgentHostModePicker` and `AgentHostClaudePermissionModePicker` share the generic `AgentHostSessionEnumPicker` mechanics: resolve the active schema, render action-list rows, write selected enum values back through the provider, and report picker telemetry for real enum choices. The shared enum picker is generic by design. It exposes footer extension hooks (`_getFooterActionItems`, `_handleFooterActionItem`) but does not know about permissions, docs URLs, or Claude-specific labels. The Claude subclass contributes the separator + `Learn more about permissions` row and opens the Claude permission-mode docs from its own handler; footer rows are consumed before config writes or telemetry for enum choices.

The generic picker path still applies auto-approve policy filtering for conforming values that render outside the unified widget: `chat.autopilot.enabled` hides `autopilot`, and a policy value of `chat.tools.global.autoApprove = false` disables both `autoApprove` and `autopilot` choices. Elevated choices show one warning per VS Code session; confirming `autopilot` also counts as accepting the lower `autoApprove` warning.

## Why the visibility check has to be reactive

Both widgets need to *react* to changes in the active session — the active session can change while the action view item is alive (e.g. user navigates back to the new-chat view from a running session). Two consequences:

- **`IActionViewItemService` factories run once per render**, not once per check. A one-shot "is this an agent-host session?" check at construction time would freeze the picker into whatever state it had when the menu first rendered. Both widgets thread the `isApplicable` observable through and call `display = visible ? '' : 'none'` in an `autorun`.
- **The base `PermissionPickerActionItem` renders its label pull-style** via `refresh()`. Subclasses that drive the level externally (like `AgentHostPermissionPickerActionItem`) must add an `autorun` over `delegate.currentPermissionLevel` to call `refresh()` themselves; the base doesn't subscribe.

## Tests

`src/vs/sessions/contrib/providers/agentHost/test/browser/agentHost/agentHostPermissionPickerDelegate.test.ts` covers:

- `isWellKnownAutoApproveSchema` — exact match, missing `default`, extra enum values, wrong type.
- `currentPermissionLevel` — derives from active session's `autoApprove` value, falls back to `Default` when missing/unrecognized, updates on provider config-change.
- `setPermissionLevel` — routes to `provider.setSessionConfigValue`, no-op when no active session.
- `isApplicable` — reacts to active-session changes and to schema-shape changes.

The tests use a fake provider and exercise the delegate in isolation. The common widgets still rely on broader integration coverage, but `src/vs/sessions/contrib/providers/agentHost/test/browser/agentHostClaudePermissionModePicker.test.ts` now covers the Claude enum-picker footer path directly: selecting `Learn more about permissions` opens the docs URI and does not write a session-config value.

## Where to edit

- A change to the well-known schema or the recognition predicate → `agentHost/agentHostPermissionPickerDelegate.ts` (and the test file).
- A change to **how either widget renders** (label, icon, dropdown contents, warning dialog, "Learn more" link) → the widget file itself. The two widgets diverged on purpose; consider whether a fix needs to land in both.
- A change to workbench-only extension-contributed permission groups → `PermissionPickerActionItem` and the contributing provider delegate. Agent-host `autoApprove` should continue to flow through `AgentHostPermissionPickerDelegate` unless the AHP session-config convention itself changes.
- A change to the menu wiring (which factory registers for which menu) → `agentHostSessionConfigPicker.ts`.
- The font/size/spacing of the new-chat-page picker → CSS rules under `.new-chat-in-session …` in `src/vs/sessions/contrib/chat/browser/media/newChatInSession.css`. The chat input toolbar's picker inherits the workbench `.chat-input-picker-item` styles; that's the right place for any toolbar-specific tweaks.
- Any change to `PermissionPickerActionItem`'s constructor signature (e.g. an added injected service) cascades to `AgentHostPermissionPickerActionItem`, which has to forward the new parameter explicitly to `super()`.

## Related

- [agent-host-topology](./agent-host-topology.md) — the "well-known property names" convention this picker hangs off of.
- [agent-host-sessions-providers](./agent-host-sessions-providers.md) — `IAgentHostSessionsProvider.getSessionConfig` / `setSessionConfigValue` / `onDidChangeSessionConfig`, which back the delegate.
- [agent-host-protocol](./agent-host-protocol.md) — `SessionConfigPropertySchema` shape and the session-state subscription model.

## Debt & gotchas

- **gotcha** (2026-04-20, agentHostPermissionPickerActionItem.ts:constructor) — this subclass forwards every constructor parameter of `PermissionPickerActionItem` to `super()`. When the workbench base class gains a new injected service (it gained `IStorageService` once already), the subclass **must** be updated in lockstep — TypeScript will catch the missing argument, but only after the base class change merges. If you touch `PermissionPickerActionItem`'s constructor, search for subclasses before pushing.
- **gotcha** (2026-04-20, agentHostPermissionPickerDelegate.ts:isWellKnownAutoApproveSchema) — recognition is by enum *shape*, not by property name alone. An agent that advertises `autoApprove` with extra enum values (or a different `type`) deliberately falls back to the generic per-property picker. Don't relax the predicate to "only check that `default` is present" without weighing what new enum values would mean for the unified picker UI (which has no rendering path for unknown levels).
- **gotcha** (2026-04-20, agentHostPermissionPickerActionItem.ts:render + permissionPicker.ts:render) — `IActionViewItemService` factories run once per render, so any "should this picker be visible right now?" check that depends on dynamic state (active session, schema shape) **must** be wired through an observable + `autorun` that toggles `style.display`. Don't move the check into the factory body; the active session can change while the view item is alive.
- **gotcha** (2026-05-15, agentHostSessionConfigPicker.ts:Claude permissionMode registration) — the dedicated Claude `permissionMode` picker is for running sessions in `ChatInputSecondary`; new sessions intentionally keep `permissionMode` in the generic `NewSessionRepositoryConfig` chip lane. Do not add a dedicated `Menus.NewSessionControl` Claude picker unless the new-chat toolbar layout is deliberately being redesigned.
- **gotcha** (2026-05-15, agentHostPermissionPickerActionItem.ts:render) — an inapplicable running-session picker must hide its outer render container, not only the inner label element. `.chat-input-picker-item` carries toolbar min-width/layout participation, so inner-only hiding leaves an empty gap beside visible controls.

## Setting rename and approval modes

The session-default-configuration setting was renamed `chat.agentSessions.defaultConfiguration` → **`chat.defaultConfiguration`** (`ChatConfiguration.DefaultConfiguration`, shape `IChatDefaultConfiguration` with `mode` + `approvals`; old key deprecated/migrated in `chat.shared.contribution.ts`). The picker exposes the three modes — Interactive / Plan / **Autopilot** — and elevated permission changes confirm through `maybeConfirmElevatedPermissionLevel(...)` keyed on `ChatConfiguration.DefaultConfiguration`.

## Changelog

- **2026-06-25** — 09c18fe5c5 — reconciliation: added a **Setting rename and approval modes** section (`chat.agentSessions.defaultConfiguration` → `chat.defaultConfiguration`, `IChatDefaultConfiguration` mode/approvals, the Autopilot mode, and `maybeConfirmElevatedPermissionLevel`). The well-known-`autoApprove`-enum recognition and two-picker architecture are unchanged.

- **2026-05-15** — 12443ea83d — reconciliation: mechanical path audit refreshed the moved Copilot new-chat permission-picker path; the doc's covered Agent Host picker area had no additional post-baseline behavioral drift.

- **2026-05-15** — bb32c5e7de — documented Claude Agent Host `permissionMode` picker placement, generic enum footer-hook ownership, the toolbar-wrapper visibility gotcha, and focused footer-path test coverage.

- **2026-05-04** — 939d3f227c — reconciliation: updated the new-chat picker wording after `2fc10e36d28` introduced the mobile-aware `MobilePermissionPicker`; no body change needed for sandbox/network-option picker polish (`e7c6e7ebea2`) because the delegate/schema architecture is unchanged.

- **2026-05-01** — b2e6267136 — reconciliation: documented the dedicated well-known `mode` picker and generic-picker auto-approve filtering after `75ec86b07f24`; no structural changes needed for the picker polish / policy-level commits because the existing delegate and schema sections still describe the architecture.
- **2026-04-24** — `5407371c47` — reconciliation: well-known config keys moved to `src/vs/platform/agentHost/common/sessionConfigKeys.ts` (`SessionConfigKey.AutoApprove`, `KNOWN_AUTO_APPROVE_VALUES`) as the platform-side source of truth; the delegate's own `AUTO_APPROVE_PROPERTY` constant is gone (commit `1453f5b4e9b`). Noted that `SessionConfigPropertySchema` widened beyond string-enum (now `string|number|boolean|array|object` with `items`/`properties`/`required`) and that the recognition predicate still narrows to string-enum on purpose. Centralized agent-host schema descriptors now live in `agentHostSchema.ts` and are composed by `copilotAgent.resolveSessionConfig`.
- **2026-04-21** — `ad531180d0` — reconciliation: updated delegate-shape notes after `9a5b0119f0c` added workbench-only extension-contributed permission groups to `PermissionPickerActionItem`; `d844c098294` added tap handling to the sessions picker but did not change the agent-host architecture.
- **2026-04-20** — `7f8e7e0f0c` — initial entry. Captures the two-widget split (`PermissionPicker` for `NewSessionControl`, `PermissionPickerActionItem` for `ChatInputSecondary`), the shared `AgentHostPermissionPickerDelegate`, the well-known `autoApprove` schema convention and recognition predicate, the fallback to the generic per-property picker for non-conforming agents, and the reactive-visibility pattern needed for action-view-item factories.
