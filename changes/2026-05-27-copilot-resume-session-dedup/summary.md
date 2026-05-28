# Dedupe concurrent `_resumeSession` calls in CopilotAgent (+ shutdown-race guard)

**Date:** 2026-05-27
**VS Code branch:** agents/please-look-at-these-two-log-dumps-i-7c9797be
**VS Code SHA at finalize:** 413ef42c9d
**PR:** [#318636](https://github.com/microsoft/vscode/pull/318636)

## What was done

Diagnosed and fixed a race in `CopilotAgent` (in-process Local Agent Host provider) where two concurrent `_resumeSession(sessionId)` callers — typically the `getSessionMessages` subscribe path and `sendMessage`'s outdated-config evict-and-resume path — would each construct a `CopilotAgentSession`, and the second `_sessions.set(...)` on the underlying `DisposableMap` would dispose the first mid-`initializeSession()`. The user-visible symptom is a chat widget that opens but where `send` does nothing, accompanied by storms (`~550 occurrences` in the reporter's log) of `Trying to add a disposable to a DisposableStore that has already been disposed` warnings.

The fix adds a per-`sessionId` in-flight promise cache (`_resumingSessions`) and splits the method into a sync dedup wrapper (`_resumeSession`) and an async impl (`_doResumeSession`). Both `_doResumeSession` and `_materializeProvisional` now register in `_sessions` only **after** `initializeSession()` succeeds, and dispose the half-built `CopilotAgentSession` on init throw.

Copilot review caught a secondary regression that the deferred registration introduced: an in-flight resume whose `initializeSession()` resolves after `dispose() -> shutdown() -> super.dispose()` would call `_sessions.set(...)` on a disposed `DisposableMap`. Added a `_registerInitializedSession(sessionId, agentSession)` helper that bails (dispose + `CancellationError`) when `_shutdownPromise` is already set, and routed both post-init register sites through it.

Added 5 focused unit tests in `copilotAgent.test.ts` (4 dedup + 1 shutdown-race) and validated against a live Code OSS build via the `launch` skill: 0 disposed-store warnings in the agent host log, vs 550 in the reporter's original log.

## Key decisions

- **Wrapper/impl split rather than reworking `_sessions` as the dedup key.** `_sessions` is a `DisposableMap` that has well-defined ownership semantics ("the registered session is fully initialised and ready to be torn down by the map's dispose"). Promoting "this resume is in flight" into the same data structure would have muddled those semantics. A separate `_resumingSessions: Map<string, Promise<CopilotAgentSession>>` keeps the in-flight state in its own bucket.
- **Identity-checked cleanup** (`if (this._resumingSessions.get(sessionId) === promise)`). A late `.then(cleanup)` from an original promise that's already been replaced by another in-flight resume must not delete the new entry.
- **`_registerInitializedSession` as a single helper used by both register sites** instead of inlining the `_shutdownPromise` guard at each call. Keeps the cancel semantics in one place and makes the intent explicit (`CancellationError`, not generic `Error`).
- **Don't unify `TestableCopilotAgent._resumeSession` override with the new dedup wrapper.** The existing scaffolding intentionally bypasses the wrapper to splice in a fake session. The new dedup tests use a plain `createTestAgent(disposables)` and monkey-patch `_doResumeSession`; that's the impl method the wrapper memoizes. Documented in the testing-pattern section.
- **Use the `launch` skill for live validation rather than just relying on unit tests.** The original symptom (`Trying to add a disposable to a DisposableStore...` warning storms) is observable in the agent host log even without auth; a fresh launch confirmed 0 occurrences vs the reporter's 550, which is the regression bar.

## What went wrong or was misunderstood

- **First diagnosis blamed an "EH restart cascade" from the network event.** The user pushed back with a second log where an EH restart did NOT reproduce the bug, which forced a re-look. The actual signature — 550 identical `Trying to add a disposable to a DisposableStore that has already been disposed` warnings — pointed straight at a `DisposableMap.set` race; I should have counted that signature first. — **prevented by:** new `## Session resume dedup` section on [copilot-agent-provider](../../docs/copilot-agent-provider.md#session-resume-dedup-and-post-init-registration) and the matching gotcha; future agents reading the doc will see the symptom-to-root-cause mapping (`Trying to add a disposable ...` warning + blank chat that won't send = concurrent `_resumeSession`).
- **Prior commit `9fd36a049db` ("avoid leaking subscriptions when disposed during init") hid the leak warning but left the user-visible bug intact.** It made `_subscribeToEvents` throw `CancellationError` when `_store.isDisposed` after the wrapper-factory await; `getMessages` swallowed the error → empty array, and `sendMessage` rejected → no agent invocation. The visible symptom (blank chat, send goes nowhere) was unchanged. — **prevented by:** the new `## Session resume dedup` section explicitly calls out the symptom path through both subscribe and send, so a future agent reading the doc won't be tempted to "fix" the next instance by suppressing the throw rather than addressing the race.
- **First `launch`-skill validation attempt used `npm run transpile-client` instead of `npm run compile`.** The launcher's `preLaunch.ts` only checks for `out/`, not for `extensions/*/out/`, so it skipped the compile. Result: built-in extensions like `typescript-language-features`/`json-language-features`/`terminal-suggest` failed to activate with `Cannot find module .../extensions/.../out/...`. Had to kill the instance, run a full `npm run compile` (1.88 min), and relaunch. — **prevented by:** updates to `.agents/skills/launch/SKILL.md` (in the same branch) that call out the `transpile-client → preLaunch-skips-compile` trap in both the prerequisites and the troubleshooting section, plus an explicit `npm install / node_modules` prereq.
- **First fix introduced a new race that Copilot review caught.** Deferring `_sessions.set` until after `initializeSession()` resolved meant `shutdown()` (which iterates `_sessions`) wouldn't see in-flight resumes, and a late `_sessions.set(...)` could land on a disposed `DisposableMap`. — **prevented by:** the new `## Session resume dedup` section explicitly documents the `_registerInitializedSession` + `_shutdownPromise` guard pattern, and the matching gotcha says "do not collapse the wrapper/impl split and do not remove the shutdown guard". Lesson for future work: when changing **when** something registers in a lifecycle-aware collection, audit every consumer that iterates that collection, including `dispose()`/`shutdown()` paths.
- **Test infrastructure trap rediscovered.** `TestableCopilotAgent._resumeSession` override bypasses the new dedup wrapper — tests written on top of it can't exercise the per-id promise cache. I had to figure this out by reading the test file and trying a real `CopilotAgent` instead. — **prevented by:** new note in the [testing pattern](../../docs/copilot-agent-provider.md#testing-pattern) section calling this out, with the recommended pattern (real `CopilotAgent` + monkey-patched `_doResumeSession`).
- **Bug-bash overlap not noticed initially.** The 2026-05-26 debt entry already documented the symptom "pre-existing sessions ... sending any new prompt fails with 'Sorry, no response was returned'". I didn't connect it to the race until writing the retrospective. — **prevented by:** updated the 2026-05-26 debt entry to flag the connection (read-only-after-restart half is *plausibly* fixed by this PR; left it open pending bug-bash retest).

## What we learned

- **Live-validate AH lifecycle fixes by counting log signatures, not by manual UI poking.** The disposed-store warning is loud enough (every `_register` after a store is disposed adds a stack trace) that grepping the agent host log for it is a reliable regression check, even when the user-visible symptom requires a sign-in to reproduce. This bypassed the slim-profile-not-authed problem on the validation run.
- **`launch` skill + `npm run compile` is non-negotiable for any AH end-to-end check.** `transpile-client` is fine for unit tests under `npm run test-node`, but it silently breaks built-in extensions in the launched window without preLaunch noticing. The skill's prerequisites have been tightened to call this out.
- **Copilot code review on a fresh PR caught a real lifecycle-interaction bug** that the unit tests didn't surface. Worth attaching it early on `dispose()`-sensitive provider changes — it's a useful second pair of eyes for "did you audit all consumers of this data structure?".

## Doc updates

- **`docs/copilot-agent-provider.md`**
  - Added new section "Session resume dedup and post-init registration" with the dedup wrapper + `_registerInitializedSession` + `_shutdownPromise` guard explanation.
  - Updated the testing-pattern section to note that `TestableCopilotAgent._resumeSession` bypasses the dedup wrapper and what the dedup tests do instead.
  - Updated the 2026-05-26 debt entry: half (read-only-after-restart) qualified as plausibly resolved pending bug-bash retest; the other half (just-created session missing from sidebar) left open.
  - Added new gotcha (2026-05-27, copilotAgent.ts:_resumeSession / _doResumeSession / _registerInitializedSession) keeping the wrapper/impl split and the shutdown-race guard intact.
  - Added changelog entry referencing PR [#318636](https://github.com/microsoft/vscode/pull/318636).
- **`.agents/skills/launch/SKILL.md`** (project skill, edited in the VS Code branch, not the knowledge repo)
  - Added explicit `node_modules / npm install` prereq.
  - Added a `> Trap` callout for the `transpile-client → preLaunch-skips-compile → broken built-in extensions` failure mode in both prerequisites and troubleshooting.
  - Added a "don't give up if launched window needs sign-in; ask the user" note.
