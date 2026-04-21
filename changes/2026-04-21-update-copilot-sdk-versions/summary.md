# Update @github/copilot SDK to ^1.0.28

**Date:** 2026-04-21
**VS Code branch:** roblou/agents/update-copilot-sdk-versions
**VS Code SHA at finalize:** 4da62d3b09
**PR:** https://github.com/microsoft/vscode/pull/311807

## What was done

Bumped `@github/copilot` in the root and remote `package.json` from `^1.0.24` to `^1.0.28` (matching what the bundled copilot extension already pins) and regenerated both lockfiles.

While validating the bump, found and fixed two adjacent issues:

1. The real-SDK integration tests in `protocol/toolApprovalRealSdk.integrationTest.ts` had been failing with `No agent provider registered for: copilot` since the 2026-04-20 rename — six stale `'copilot'` provider-id literals updated to `'copilotcli'`.
2. There was no real-SDK test asserting the *shape* of models returned by `_listModels`. Added a `listModels returns well-shaped model entries after authenticate` test that subscribes to root state, authenticates, waits for `root/agentsChanged`, and asserts every model has a string `id`/`name`, `provider === 'copilotcli'`, and a numeric `maxContextWindow > 0`. This guards against the failure mode that motivated the downgrade (see "Key decisions" below).

## Key decisions

- **Pin to 1.0.28 (not 1.0.34, the latest).** Started with 1.0.34, found at runtime that `_listModels` throws `TypeError: Cannot read properties of undefined (reading 'max_context_window_tokens')` because the bundled CLI server's `api.schema.json` makes `ModelCapabilities.limits` optional in 1.0.34 while `@github/copilot-sdk@0.2.2`'s `.d.ts` still declares it required. At least one model returned by 1.0.34 omits `limits` entirely. Backing off to 1.0.28 — the version `extensions/copilot/package.json` already uses — restores the schema invariant (`required: ['supports', 'limits']` + `limits.required: ['max_context_window_tokens']`) so the strict TS dereferences in `_listModels` are safe.
- **Strict dereferences over defensive `?.`.** First mitigation while still on 1.0.34 was to add `?.` chains on `m.capabilities?.limits?.max_context_window_tokens`. Reverted these on 1.0.28 — the schema guarantees the fields, and adding `?.` permanently both hides future SDK drift and silently produces `undefined` for `maxContextWindow`. Better to keep the strict form, document the SDK pin invariant, and let the new real-SDK test loudly catch any future drift.
- **Add the regression test to the existing `toolApprovalRealSdk.integrationTest.ts`, not a new file.** Keeps env-gating + auth setup in one place. For convenience the convention `*RealSdk.integrationTest.ts` lets you run all real-SDK tests via `--runGlob "**/*RealSdk.integrationTest.js"` if more files appear later.
- **Did not fix the two pre-existing real-SDK failures.** `planning-mode` (`SessionOptions.onExitPlanMode` not wired into `CopilotAgentSession`) and `subagent` (`approvalLoop` never exits on timeout, hangs past 180s) reproduce on 1.0.24 too. Out of scope for this PR; recorded in `testing.md` debt for a future change to pick up.

## What went wrong or was misunderstood

- **Initial assumption "latest is safe."** Bumped straight to ^1.0.34 without checking what `extensions/copilot/package.json` pins. The copilot extension is the closest thing we have to a known-good baseline because Copilot ships and tests it. — **prevented by:** new `gotcha` on `copilot-agent-provider.md` saying root and remote `@github/copilot` should track `extensions/copilot/package.json`.
- **`_refreshModels` swallows errors.** Spent a long time chasing "models don't show up after authenticate" before the user pasted the actual stack trace. The catch block at lines 225–229 was added for the legitimate `AHP_AUTH_REQUIRED` case (per the existing 2026-04-20 gotcha) but happily swallows every other throw too — SDK schema mismatches, network errors, anything. Symptom is silent: empty model list in UI, no surfaced error, no log. — **prevented by:** new `gotcha` on `copilot-agent-provider.md` calling out the broader silent-failure surface, plus the new real-SDK `listModels` test as the safety net for non-auth failures.
- **No real-SDK coverage for the auth → models pipeline.** All existing real-SDK tests focused on tool approval / turn execution; nothing asserted the shape of `rootState.agents[*].models`. A bug in `_listModels` could only be discovered by manually running the agent host and trying to pick a model. — **prevented by:** the new `listModels` test, and an addition to `testing.md` § 3 ("When to use") explicitly calling out SDK type-vs-schema drift as something only real-SDK tests catch.
- **Stale `'copilot'` provider id in the env-gated test file.** The 2026-04-20 rename gotcha for `copilotAgent.test.ts` already existed, but it didn't mention `protocol/toolApprovalRealSdk.integrationTest.ts`. Worse, that file is gated on `AGENT_HOST_REAL_SDK=1` and is not run by CI, so the broken provider id had been silently failing for ~24 hours. TypeScript can't help: `AgentSession.uri('copilot', ...)` takes the provider as a plain `string`. — **prevented by:** extending the existing rename-audit `gotcha` on `copilot-agent-provider.md` to explicitly include the real-SDK file, plus a new `gotcha` on `testing.md` calling out the suite's invisibility to CI.
- **SDK `.d.ts` lies.** `@github/copilot-sdk@0.2.2`'s `ModelCapabilities` declares `supports` and `limits` as required, but the bundled server in `@github/copilot@1.0.34` makes both optional. TypeScript is no help — the runtime shape disagrees with the compile-time shape and the failure mode is a `TypeError` at first dereference. — **prevented by:** the SDK pin gotcha (treat the schema as the source of truth, pin to a `@github/copilot` version whose schema matches the SDK types), plus the runtime shape-asserting test.
- **Investigated the wrong worktree initially.** When the user reported "models don't show up", I started looking at `agents-local-agent-host-coexistence` instead of `agents-update-copilot-sdk-versions` — confused the two branches. Cost a few turns. Not a knowledge-base item; just a workflow miss to keep in mind when the user is running multiple worktrees.

## What we learned

- `@github/copilot` ships *both* a JS SDK lib (typed via `@github/copilot-sdk`) and a bundled CLI server (with its own JSON schema). They version in lockstep within the package but the schema and types are independently authored and can disagree. The schema is the runtime source of truth.
- `extensions/copilot/package.json` is a useful "known-good version" reference for any package the copilot extension consumes — that extension is shipped and exercised by the Copilot team's own validation.
- The `*RealSdk.integrationTest.ts` naming is a usable convention for grouping env-gated tests; `--runGlob "**/*RealSdk.integrationTest.js"` runs the lot.

## Doc updates

- `docs/copilot-agent-provider.md` — three new `gotcha` entries: (1) `package.json:@github/copilot` should track `extensions/copilot/package.json`'s pin; (2) `_refreshModels` swallows ALL throws, not just auth, with the new real-SDK test as the only safety net; (3) extended the existing rename-audit gotcha to call out `protocol/toolApprovalRealSdk.integrationTest.ts` and document why env-gated test files are extra-vulnerable to identifier drift.
- `docs/testing.md` — added `listModels` worked example to § 3 ("When to use" for real-SDK tests, calling out SDK type-vs-schema drift as a class of bug only this layer catches); added two `gotcha` entries: (1) the real-SDK file is invisible to CI and so prone to silent string-identifier rot; (2) `planning-mode` and `subagent` tests in that suite are known-broken pre-existing failures.