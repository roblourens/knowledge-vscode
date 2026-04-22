# Bump @github/copilot to 1.0.34 with consumer-side wrapper

**Date:** 2026-04-22
**VS Code branch:** roblou/agents/bump-github-copilot-packages
**VS Code SHA at finalize:** d6e5c5227d
**PR:** https://github.com/microsoft/vscode/pull/311964 (draft)

## What was done

Bumped `@github/copilot` in the root and remote `package.json` from `^1.0.28` to `^1.0.34` (matching the bundled copilot extension's pin) and regenerated both lockfiles.

This revisits the 2026-04-21 decision — that session bumped to 1.0.28 instead of 1.0.34 *specifically* because of the `_listModels` `TypeError` crash, treating the SDK pin as the source of safety. This session takes the opposite approach: track `extensions/copilot` (which is already on 1.0.34) and fix the underlying type/runtime drift at the consumer side.

The fix:

1. **`ICopilotModelInfo` wrapper** in `src/vs/platform/agentHost/node/copilot/copilotAgent.ts` — hand-typed mirror of the SDK's `ModelInfo` with `capabilities`, `capabilities.limits`, `capabilities.supports`, and `max_context_window_tokens` all marked optional. `ICopilotClient.listModels` is typed against the wrapper, so direct dereferences are properly nullable-checked at compile time.
2. **`IAgentModelInfo.maxContextWindow?: number`** in `src/vs/platform/agentHost/common/agentService.ts` — was already optional in the AHP protocol's `state.ts` but the workbench-facing interface had it required. Now matches.
3. **`_listModels` uses `.map`, not `.flatMap`** — the synthetic `auto` router model surfaces in the returned list with `maxContextWindow: undefined`. The consumer in `agentHostLanguageModelProvider.ts` already coalesces with `?? 0`.
4. **Updated `listModels returns well-shaped model entries after authenticate`** real-SDK test to tolerate `undefined` `maxContextWindow` and to assert `auto` is in the returned list.

Also merged `connor4312/ah-session-settings-2` into this branch (158 files; orthogonal session-settings work the user needed).

## Key decisions

- **Consumer-side wrapper over upstream report.** User explicitly asked not to file an upstream issue. The `ICopilotModelInfo` interface launders the unsafe SDK type into a properly nullable one *at the boundary* (`ICopilotClient.listModels`) so the rest of `copilotAgent.ts` operates on truthful types. Preferred over scattering `?.` chains through the consumer code or wrapping the SDK call in a `try/catch`.
- **Surface `auto`, do not drop it.** First instinct (and the previous session's defensive instinct) was to skip models with empty `capabilities`. That's wrong: `auto` is the router model that powers Copilot's "let me pick a model for you" mode and the model picker UI depends on it being present. The right move is to make `maxContextWindow` honestly optional.
- **Bump despite the known crash.** Previous session backed off to 1.0.28 *because* of this crash. The "track `extensions/copilot`" gotcha (added in that same session) is the long-term correct stance — pinning to a different version than the extension is fragile. So we accepted the crash as a forcing function for the wrapper fix.
- **Did not touch `_refreshModels` swallow-everything `catch`.** Still swallows. The 2026-04-21 gotcha noting this is still accurate; not in scope for this PR.

## What went wrong or was misunderstood

- **First instinct was a defensive `flatMap` to skip `auto`.** Same trap the previous session fell into. User pushed back and asked for a proper investigation — which led to using the existing real-SDK `listModels` test as a harness (with a `writeFileSync('/tmp/copilot-models-diag.json', …)` injected into `_listModels`) to discover the actual shape: `{ id: 'auto', name: 'Auto', capabilities: {} }` among 21 well-shaped models. Lesson: when the SDK shape disagrees with the SDK types, capture the runtime shape first, then design the type wrapper from that — don't just `?.` the dereferences.
- **Initial fix dropped `auto` entirely.** Even with the correct wrapper, the first version of `_listModels` returned `flatMap(m => m.capabilities?.limits?.max_context_window_tokens === undefined ? [] : [...])` — silently hiding `auto` from the model picker. User caught it: "I don't want you to skip the auto model." Lesson: missing data ≠ broken model. If a synthetic/router entry exists at runtime, surface it with the missing field as undefined rather than filter it out, and let the consumer decide.
- **Wrong git inspection of `connor4312/ah-session-settings-2`.** I checked `FETCH_HEAD` (already-stale from a prior fetch) and confidently told the user "already merged." User pushed back; the actual `origin/connor4312/ah-session-settings-2` had hundreds of commits we didn't have. Lesson: when checking "is X merged?", compare against the *remote-tracking* ref (`git log HEAD..origin/branch --oneline | wc -l`), never `FETCH_HEAD`.
- **`.knowledge` symlink and the two `init-session.sh` scripts.** This session's first init pointed at a stale orphan worktree under `/Users/roblou/code/knowledge-vscode/skills/init/.worktrees/...` (the orphan `skills/init/` script lives outside `vsckb/`). The correct script is `/Users/roblou/code/knowledge-vscode/vsckb/skills/init/scripts/init-session.sh`. Already noted in the index.md `gotcha` from 2026-04-21; this session re-tripped it. Lesson: always verify `.knowledge/index.md` resolves and points at the real KB before doing anything else.

## What we learned

- **Treat SDK types as a hint, not a contract.** The `auto` model has been in `@github/copilot`'s `listModels()` for several versions; the SDK type just doesn't reflect it. When a third-party SDK type disagrees with a known runtime shape, prefer a local typed wrapper at the call site over `?.` chains scattered through callers — the wrapper is one place to maintain and self-documents the gap.
- **Real-SDK tests double as runtime probes.** Adding a one-line `writeFileSync('/tmp/...json', JSON.stringify(models))` to `_listModels` and re-running the existing `listModels` test was the fastest way to capture the actual SDK output shape. The test already drives auth + `_refreshModels`; it just needed a leaked-data side channel. Worth remembering for future SDK-shape mysteries.
- **Optional `maxContextWindow` is the honest type.** AHP's `state.ts` already had it optional; the workbench-side `IAgentModelInfo` mirror was wrong. Matching the protocol's optionality removes the need for adapter-side fabrication or filtering.

## Doc updates

- `docs/copilot-agent-provider.md` — updated the 2026-04-21 `package.json:@github/copilot` gotcha (kept the "track extensions/copilot" rule; removed the stale "1.0.34 is broken" claim — the wrapper now handles it). Added a new gotcha for `ICopilotModelInfo` + `IAgentModelInfo.maxContextWindow?` documenting the wrapper pattern, why `auto` MUST surface (router-mode picker depends on it), and the "extend the wrapper, don't `?.` the consumer" guidance.
- `docs/testing.md` — refreshed the `listModels` example in § 3 to reflect the new failure mode (synthetic `auto` model with empty `capabilities`, not a missing `limits` field) and the consumer-side wrapper fix.
