# Agent Host Claude Permission Picker Placement

**Date:** 2026-05-15
**VS Code branch:** roblou/agent-host-claude-permission-picker
**VS Code SHA at finalize:** bb32c5e7de
**PR:** [#316735](https://github.com/microsoft/vscode/pull/316735)

## What was done
The VS Code branch restores the Agents-specific Copilot approval picker behavior and adds a parallel Claude Agent Host permission-mode picker for running sessions. It shares the enum-picker mechanics between mode-like session-config controls while keeping provider-specific behavior in subclasses.

The final shape keeps Claude `permissionMode` on the existing generic new-session config chip lane, adds the dedicated Claude picker only to the running-session chat toolbar, fixes hidden Agent Host toolbar picker wrappers so they do not reserve empty width, and adds a subclass-owned `Learn more about permissions` footer action plus focused coverage proving it opens docs without writing config.

## Key decisions
- Keep new-session Claude `permissionMode` in `Menus.NewSessionRepositoryConfig`; use the dedicated Claude picker only for running sessions in `ChatInputSecondary`, so the new-chat toolbar lanes remain visually coherent.
- Keep `AgentHostSessionEnumPicker` generic. It exposes footer extension hooks, while `AgentHostClaudePermissionModePicker` owns its localized Learn More row and docs URI.
- Hide inapplicable running-session picker action containers at the outer render container, because hiding only the inner label leaves `.chat-input-picker-item` toolbar width behind.
- Add focused picker coverage for the Learn More footer path after review identified that this new non-enum selection branch deserved a direct assertion.

## What went wrong or was misunderstood
- The first Claude new-session implementation treated `permissionMode` like a dedicated control-lane action, but that moved it left of the repository/config lane and looked wrong — **prevented by:** `gotcha:` on `agent-host-auto-approve-picker.md` plus the doc body update describing the split between `NewSessionRepositoryConfig` and `ChatInputSecondary`.
- Hiding only the inner Agent Host permission picker label looked sufficient in code, but the outer `.chat-input-picker-item` wrapper still contributed toolbar min-width and produced an empty gap — **prevented by:** `gotcha:` on `agent-host-auto-approve-picker.md` documenting outer-container visibility as load-bearing.
- The first pass put Claude's permission-doc footer behavior into the shared enum picker, which made the supposedly generic base know about a product-specific link — **prevented by:** doc body update on `agent-host-auto-approve-picker.md` explaining the generic footer hooks and subclass-owned Claude action.
- Review found the new footer selection path had no direct regression coverage, even though it must avoid config writes and enum-choice telemetry — **prevented by:** doc body update noting `agentHostClaudePermissionModePicker.test.ts` and this summary's rationale.

## What we learned
- The toolbar menu id is not enough to infer visual grouping; in new chat, control-lane and config-lane ownership determine whether a picker reads as part of the right workflow.
- Picker invisibility needs to be reasoned about at the action-view-item container level whenever toolbar layout CSS attaches width to a wrapper instead of the label.
- Shared picker abstractions can stay small if provider-specific affordances are modeled as optional footer action rows with subclass-owned handling.

## Doc updates
- Updated `docs/agent-host-auto-approve-picker.md` covers paths, body text, tests section, and changelog for Claude `permissionMode` behavior.
- Added `gotcha:` entries for Claude new-session placement and outer-container hiding of inapplicable toolbar pickers.
- No docs were created or removed.
