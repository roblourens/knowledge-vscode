# Reuse permission picker widgets for the agent host auto-approve picker

**Date:** 2026-04-20
**VS Code branch:** agents/refactor-auto-approve-picker-widget
**VS Code SHA at finalize:** 7f8e7e0f0c
**PR:** https://github.com/microsoft/vscode/pull/311263

## What was done

Replaced the bespoke agent-host auto-approve picker (which duplicated three near-identical implementations of label/icon switching, warning dialogs, autopilot gating, and policy enforcement) by reusing the **two existing permission picker widgets** in their natural rendering contexts:

- `src/vs/sessions/contrib/copilotChatSessions/browser/permissionPicker.ts`'s `PermissionPicker` for the Agents app's new-chat page (`Menus.NewSessionControl`).
- `src/vs/workbench/contrib/chat/browser/widget/input/permissionPickerActionItem.ts`'s `PermissionPickerActionItem` for the running chat input toolbar (`MenuId.ChatInputSecondary`).

A single new delegate, `AgentHostPermissionPickerDelegate`, drives both. Both widgets accept the same delegate shape (`currentPermissionLevel`, `setPermissionLevel`, optional `isApplicable`), so the delegate is widget-agnostic. Recognition of the well-known `autoApprove` schema (string enum subset of `default | autoApprove | autopilot`, contains at least `default`) lives in `isWellKnownAutoApproveSchema`. Non-conforming agents fall back to the generic per-property picker.

The deleted code: the entire `AgentHostNewSessionApprovePicker` class, the entire `AgentHostRunningSessionConfigPicker` class, plus the duplicated `applyAutoApproveFiltering`, `confirmAutoApproveLevel`, and `applyAutoApproveTriggerStyles` helpers.

## Key decisions

- **Two widgets, one delegate** — not "one unified widget." The new-chat page and the chat input toolbar have different ancestor CSS chains and different sizing/spacing rules. Forcing one widget into both contexts required invasive CSS rules that affected other elements. The user explicitly confirmed they were comfortable with the `PermissionPicker` ↔ `PermissionPickerActionItem` duplication; the dedup that mattered was the delegate + recognition logic, not the DOM.
- **Recognition by enum *shape*, not by property name alone.** A hostile or legacy agent that declares `autoApprove` with an unsupported enum (extra values, different `type`) does not get the unified picker — it falls back to the generic per-property picker so it still has *some* UI.
- **Reactive `isApplicable`, not one-shot.** `IActionViewItemService` factories run once per render. The active session can change while a view item is alive (e.g. user navigates back to new-chat from a running session), so visibility must come from an observable + `autorun` that toggles `style.display`.
- **`AUTO_APPROVE_PROPERTY` lives in the delegate file.** Single source of truth for the property name string; the picker file imports it.
- **Don't push the writer down to the provider.** The user asked whether moving `setPermissionLevel` onto `IAgentHostSessionsProvider` (mirroring the Copilot delegate, which delegates to the session) would simplify things. It wouldn't: the bulk of the delegate is the two reactive observables (`currentPermissionLevel` and `isApplicable`) which depend on `(activeSession, providerId, sessionId, sessionConfig)` and have to live somewhere. Only the ~10-line setter would move; the asymmetry is in the data model, not the API.

## What went wrong or was misunderstood

- **Initial assumption: a single widget could be unified across both contexts.** I tried two full implementations — first using only `PermissionPickerActionItem` everywhere (forcing it onto the new-chat page with invasive CSS overrides), then pivoting to use only `PermissionPicker` everywhere (rewiring Copilot to use a delegate). The user had to course-correct twice before we landed on the natural split. The signal was always there in the existing code (the new-chat page had its own picker for a reason), but I missed it because I was over-indexing on "deduplication" as the goal. **prevented by:** new doc [agent-host-auto-approve-picker](../../docs/agent-host-auto-approve-picker.md) — the "two-widget split (and why we keep both)" section names the contexts and explains why a single widget doesn't fit.

- **CSS scoping snowball on the new-chat page.** Multiple iterations on font-size, icon-size, gap, and color rules. Each "fix" was reactive to a screenshot the user had to provide (icons too small, text too big, chevron too small, padding wrong, etc.). The root cause turned out to be that the new-chat page has its own `.monaco-action-bar .action-label` rule at 11px that conflicts with the workbench widget's expectations, and codicons default to 16px — explicit `font-size: 16px` rules are redundant and just look like over-engineering. **prevented by:** picking the right widget for each context (see above) means the new-chat page uses `PermissionPicker`, which already styles itself correctly for that container. The CSS mess goes away when widget choice matches context.

- **Reactive show/hide had to be added late.** First implementation gated visibility at the factory body. The factory only runs once per render, so when the user navigated back to the new-chat view from a running session, the picker stayed in whatever state it had been. Caught manually by the user. **prevented by:** gotcha on new doc — "`IActionViewItemService` factories run once per render … visibility checks that depend on dynamic state must be wired through an observable + `autorun`." Generally useful pattern beyond just this picker.

- **Subclass constructor drift on merge.** `PermissionPickerActionItem` gained an `IStorageService` parameter on `main` while this branch was open. The subclass `AgentHostPermissionPickerActionItem` had to forward it explicitly. Trivial to fix (TypeScript catches it) but a real ongoing maintenance cost. **prevented by:** gotcha on new doc — pointer to subclass; if you touch the base, search for subclasses first.

- **Referenced a private knowledge doc in source code.** The agent-host topology doc is private to the user; I had referenced it from a code comment. Not an unrecoverable mistake but exactly the kind of leakage the knowledge-repo / public-repo separation is supposed to prevent. **prevented by:** rule already in `implement` skill ("Privacy: don't leak the knowledge repo into source"). Confirmed it's still there. Re-read that section every time before writing source code, not just at session start.

- **Test leak missed locally; caught by the Copilot reviewer.** An `Emitter` in the test setup wasn't disposed; would have failed `ensureNoDisposablesAreLeakedInTestSuite()` under the right conditions. **prevented by:** the existing `memory-leak-audit` skill covers this exact pattern. Should have run it on the test file before pushing.

- **Dead `_slot` field shipped initially.** Stored a local DOM reference on `this` for no reason — the `slot` const was already in scope for the `autorun` closure. Removed only after the user pointed it out. **prevented by:** during normal cleanup pass, ask "do I need this on `this`?" for every field that's only read by code in the same method that creates it.

## What we learned

- **The "structurally compatible delegate" pattern works well across layers.** `IPermissionPickerDelegate` is defined twice (once in sessions, once in workbench), with matching field names but slightly different optionality. A single concrete delegate satisfies both interfaces structurally, with no shared base type. This is a clean way to share data plumbing across two widgets that can't share their UI for layering reasons.
- **The user's instinct on duplication tolerance is calibrated.** When asked, the user said the `PermissionPicker` ↔ `PermissionPickerActionItem` duplication was acceptable — they understood the tradeoff and didn't want a forced unification. Worth taking seriously: not all duplication is bad, and sometimes the right answer is to share the *plumbing* (the delegate, the predicate) without sharing the *presentation*.
- **Iteration via screenshots is slow.** Several rounds of CSS adjustment came down to the user describing what didn't look right and pasting screenshots. The component-fixtures skill / Component Explorer is the right tool for this kind of iteration; remember to use it for visual changes.

## Doc updates

- **NEW**: `docs/agent-host-auto-approve-picker.md` — covers the well-known `autoApprove` convention, the two-widget split, the shared delegate pattern, the recognition predicate, the fallback flow, and the reactive-visibility pattern needed for action-view-item factories. Three gotchas: subclass-keeps-parent-constructor-in-sync, recognition-by-shape-not-name, and factories-run-once-per-render.
- **UPDATED**: `docs/agent-host-sessions-providers.md` — picker section now points at the new doc; "Where to edit" line split between generic per-property picker and the well-known `autoApprove` picker; Related section adds the new doc; changelog entry added.
- **UPDATED**: `docs/agent-host-topology.md` — well-known-property convention #1 now cites `autoApprove` as a concrete worked example, with a pointer to the new doc; Related and Changelog updated.
- **UPDATED**: `index.md` — new doc added to the Docs list with a keyword-rich description and `Covers:` paths.
