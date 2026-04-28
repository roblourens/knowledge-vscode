# Bump @github/copilot to 1.0.38

**Date:** 2026-04-28
**VS Code branch:** roblou/agents/update-github-copilot-dependencies
**VS Code SHA at finalize:** 5e0eb8ff17
**PR:** https://github.com/microsoft/vscode/pull/313073

## What was done

Bumped `@github/copilot` from `^1.0.34` to `^1.0.38` in both the root `package.json` and `remote/package.json` (and regenerated both lockfiles), tracking the version pinned in `extensions/copilot/package.json`. `@github/copilot-sdk` stayed at `^0.2.2`. No source changes were needed — the `ICopilotModelInfo` wrapper added in the previous bump (2026-04-22) still cleanly absorbs the SDK shape, and the real-SDK `listModels returns well-shaped model entries after authenticate` integration test passes unchanged.

Also reverted `e1811ece5bd` ("fix: skip electron re-download when correct version already present"), which another agent pushed onto this PR uninvited and is unrelated to the dependency bump.

## Key decisions

- **Track `extensions/copilot` blindly.** The "track the bundled extension's pin" gotcha is the long-standing rule; this bump exists to enforce it, not to evaluate 1.0.38 against any feature need. The real-SDK test is the safety net.
- **Don't touch `@github/copilot-sdk`.** The user only asked for `@github/copilot`. The SDK's `peerDependency`-style `"@github/copilot": "^1.0.21"` recorded in lockfiles is satisfied by 1.0.38.
- **Revert via a normal commit, not force-push.** Per the standing "never force-push" rule, the unwanted electron-download commit was reverted with a regular `git revert` so the PR history preserves what happened.

## What went wrong or was misunderstood

- **Skipped the real-SDK integration test on the first pass.** I checked env for `GITHUB_TOKEN` / `COPILOT_TOKEN`, didn't find one, assumed the test couldn't run, and declared the bump done without it. The test reads from `gh auth token` as a fallback (literally documented in `resolveGitHubToken()` in the test file itself, and in `docs/testing.md` § 3). Should have just *tried* it. — **prevented by:** an existing-and-already-correct line in `docs/testing.md` § 3 ("Auth comes from `gh auth token` by default; override with `GITHUB_TOKEN`"). The actual prevention here is process, not docs: when a doc-recommended verification step exists, run it instead of inventing a precondition for skipping it.
- **Tripped on `ELECTRON_RUN_AS_NODE=1` leaking into the shell.** First `./scripts/test-integration.sh` invocation crashed instantly with `TypeError: Cannot read properties of undefined (reading 'setPath')` at `test/unit/electron/index.js:119`. The fix (`unset ELECTRON_RUN_AS_NODE`) was already in `docs/testing.md`, but in the *workflow-tips section* far from the § 3 real-SDK invocation block I copy-pasted. — **prevented by:** moving the `unset` inline into the § 3 example block in `docs/testing.md`, and rewording the env-gated rename-audit gotcha (which had its own bare command snippet) to point back at § 3 instead of repeating the invocation without the unset. The doc is now structured so copy-pasting any real-SDK invocation includes the unset.
- **Ran the full suite once instead of `--grep`-ing the one test I cared about.** The suite is minutes; the single `listModels` test is ~2s. — **prevented by:** an explicit "add `--grep` to focus on a single test" line added to § 3.
- **Created the PR as draft for no reason.** Habit from the prior `2026-04-22-bump-copilot-1.0.34-with-wrapper` session, where draft made sense. This change had passing tests and clean diffs. User had to ask me to mark it ready. — **prevented by:** this summary. No doc rule needed; just don't reflexively use `draft: true`. The decision should be deliberate: draft = "I want the PR open for visibility but it's not yet ready for review."

## What we learned

- **The 1.0.34 → 1.0.38 SDK behavior is unchanged in the dimensions our adapter cares about.** The `auto` router model still ships with `capabilities: {}`. The wrapper layer continues to be the right shape.
- **`gh pr checks` is the right command for monitoring CI from the worktree** — `gh pr view` doesn't show check status nicely.

## Doc updates

- `docs/testing.md` — moved `unset ELECTRON_RUN_AS_NODE` inline into the § 3 real-SDK invocation block, with an explanatory note about why it leaks in. Added an explicit `--grep "<test name>"` reminder. Reworded the env-gated rename-audit gotcha to point back at § 3 instead of duplicating the bare command. Added changelog entry.
- `docs/copilot-agent-provider.md` — updated the `ICopilotModelInfo` gotcha to note the same shape is still present at 1.0.38, not just 1.0.34. Added changelog entry for the bump itself.
- No new docs, no debt entries added or removed.
