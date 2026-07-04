# Fix Agent Host Checkpoint Summary Flicker

**Date:** 2026-07-04
**VS Code branch:** agents/fix-checkpoint-flicker-issue
**VS Code SHA at finalize:** 577ed33078
**PR:** https://github.com/microsoft/vscode/pull/324282

## What was done

Fixed the Agent Host per-turn file-changes summary disappearing and reappearing while restoring a completed session. The per-turn changeset URI derived from session state was compared by object identity, so an unrelated session-state update could reconstruct an equivalent URI and replace the changeset subscription. The replacement subscription briefly exposed an empty changeset before resolving, causing the visible summary to reset from one file to zero and back.

The provider now compares derived URI values with `isEqual`, preserving the existing subscription across equivalent session-state updates. A regression test records changeset subscription acquisition and verifies that a session-state update does not subscribe again. The fix was also verified in a launched Code OSS instance using a persisted one-file-change session and a DOM mutation observer.

## Key decisions

- Fix subscription identity at the URI-valued derived rather than caching or suppressing intermediate values in the summary UI.
- Preserve the initial hidden-to-visible transition because per-turn changesets are intentionally computed lazily on subscription; this change only removes the incorrect later reset.
- Test the provider contract by counting changeset subscriptions, which directly captures the root cause instead of asserting a downstream DOM symptom.

## What went wrong or was misunderstood

- The first diagnosis attributed the flicker to individual file diffs settling and attempted to hide the summary until every diff was no longer busy. The observed behavior was actually the same summary instance receiving an empty changeset after its subscription was replaced. — **prevented by:** the new `gotcha:` and per-turn summary lifecycle text in `agent-host-git-driven-diffs.md`.
- Static inspection of the index-based chat content renderer suggested the summary might be repeatedly disposed and recreated as surrounding parts shifted. Live mutation instrumentation showed the main summary node remained the same; a later second node belonged to the agent-session hover preview. — **prevented by:** this summary's debugging narrative and validating node identity/ancestor context before changing renderer lifecycle code.
- The first launch attempts were slowed by a long macOS Unix-socket path and by having only client output compiled. — **prevented by:** using a short `TMPDIR` and compiling built-in extensions before launch, as required for a fully functional authenticated chat workflow.

## What we learned

- Per-turn changesets are lazy: subscribing to a historical turn computes its checkpoint diff, so an initial hidden-to-visible summary transition is expected with the current protocol shape.
- URI-valued observables that control nested subscriptions need semantic resource equality; object identity can turn harmless state updates into subscription churn.
- A DOM mutation observer plus stable per-node IDs was an effective way to distinguish value changes, actual rerenders, and separate hover-preview widgets.

## Doc updates

- Updated `docs/agent-host-git-driven-diffs.md` with the lazy per-turn summary lifecycle, subscription equality requirement, provider regression-test coverage, and a new `gotcha:` for URI-valued derived observables.
- No plan folder existed for this session; `plan/2026-07-04-agent-host-checkpoint-summary-flicker/` is absent.
