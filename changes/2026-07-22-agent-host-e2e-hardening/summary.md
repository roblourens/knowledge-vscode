# Harden Agent Host E2E rename snapshots

**Date:** 2026-07-22
**VS Code branch:** roblou/agents/e2e-tests-hardening-flakiness-diagnosis
**VS Code SHA at finalize:** df38e1614e
**PR:** [#327058](https://github.com/microsoft/vscode/pull/327058)

## What was done

The deterministic Copilot, Claude, and Codex provider suites were run repeatedly from fresh Electron processes locally and in temporary Linux, macOS, and Windows PR loops. The effective cross-platform loop reproduced one primary Linux Codex flake: session materialization sometimes completed after the local `/rename` snapshot round began, inserting `session/serverToolsChanged` into an otherwise deterministic rename transcript. A following iteration could then report a secondary console-cleanliness failure because the first mismatch left an `.actual` snapshot artifact.

The two local rename scenarios now use the existing `behavior` snapshot profile. Their snapshots retain the user turn, title change, response, and turn completion while excluding unrelated session-update and server-tool advertisement traffic. The affected snapshots were regenerated for all three providers, and the temporary CI loops were removed after every platform passed five complete provider iterations.

## Key decisions

- Treat `session/serverToolsChanged` as asynchronous provider-startup traffic for local rename tests, not as part of the rename contract.
- Reuse the existing `behavior` profile instead of adding a one-off filter or weakening the direct assertions.
- Keep temporary flake loops out of the final PR after they have collected enough cross-platform evidence.
- Query only the relevant Electron jobs with bounded polling rather than waiting on the whole PR check set.

## What went wrong or was misunderstood

- The testing guide named `npm run compile-check-ts-native`, but that script no longer exists; the current command is `npm run typecheck-client`. — **prevented by:** doc body update in `docs/testing.md`.
- The initial diagnostic loop was added to Azure product-build templates, but VS Code PR Electron checks run from `.github/workflows/pr-{linux,darwin,win32}-test.yml`. — **prevented by:** doc body update and `gotcha:` in `docs/testing.md`.

## What we learned

- A deterministic model fixture does not make all host traffic deterministic: provider materialization and other startup work can still race with a code-driven snapshot round.
- Snapshot mismatches can create misleading next-iteration failures through `.actual` artifact cleanup, so loop diagnosis must identify the first failure rather than count every later symptom as an independent flake.
- Five full iterations per provider on each PR platform were enough to reproduce the Linux-only ordering issue and verify the fix, while local macOS loops remained clean.

## Doc updates

- Updated `docs/testing.md` with the current type-check command and explicit GitHub Actions PR workflow paths.
- Expanded the `behavior` snapshot guidance to cover local commands and asynchronous session-update noise.
- Added gotchas for provider-materialization traffic in local-command snapshots and for the GitHub PR CI vs. Azure product-build distinction.
