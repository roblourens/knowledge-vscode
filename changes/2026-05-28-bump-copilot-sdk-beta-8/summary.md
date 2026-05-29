# Bump @github/copilot-sdk to 1.0.0-beta.8 and CLI @github/copilot to 1.0.55-3

PR [#318683](https://github.com/microsoft/vscode/pull/318683). Branch `agents/vsckb-implement-please-bump-the-github-copilot-s-85241c1a`. Head `dced3b17d10`.

## What changed

Root + `remote/` dependency bumps:

- `@github/copilot-sdk`: `1.0.0-beta.4` → **`1.0.0-beta.8`**
- `@github/copilot` (CLI): `1.0.49` → **`1.0.55-3`**

The CLI bump is forced by the SDK's `peerDependencies["@github/copilot"]: "^1.0.55-1"` — see [copilot-agent-provider gotcha](../../docs/copilot-agent-provider.md#debt--gotchas) on when the CLI is allowed to lead the extension's pin. Neither bump reached the absolute latest because `remote/.npmrc` has `min-release-age=1`, which capped us at versions ≥24h old (beta.9 and CLI 1.0.55-7 were both <24h old at the time).

SDK breaking changes adapted in `src/vs/platform/agentHost/node/copilot/`:

| Old surface | New surface |
|---|---|
| `CopilotClientOptions.useStdio` + `cliPath` + `autoStart` | `connection: RuntimeConnection.forStdio({ path: cliPath })` |
| `CopilotClientOptions.remote` | `enableRemoteSessions` |
| `SessionContext.cwd` | `workingDirectory` (3 sites + tests) |
| `session.getMessages()` | `session.getEvents()` |
| `session.destroy()` | `session.disconnect()` |
| `AssistantUsageData.copilotUsage` | (removed; dropped `_turnCopilotUsageTotalNanoAiu` + `totalPremiumRequests` shutdown trace) |
| `PermissionRequest` (concrete) extended by `ITypedPermissionRequest` | `PermissionRequest` is now a discriminated union; `ITypedPermissionRequest` rewritten as a standalone interface with optional bag-of-options fields |
| `IAgentToolPendingConfirmationSignal.permissionKind` | extended union with `'extension-management' \| 'extension-permission-access'` (new SDK PermissionRequest kinds) |
| `ToolBinaryResult.type: string` | literal `'image' \| 'resource'` |
| Hook `SessionHookInput.timestamp: number` + `cwd` | `timestamp: Date` + `workingDirectory` + new required `sessionId` |
| `tool.handler` required | now optional — call sites must use `tool.handler!` or guard |
| `SessionMode = 'agent' \| 'plan'` | `'shell'` no longer in enum; test casts via `unknown` |

Test fixes in `src/vs/platform/agentHost/test/node/`: `copilotAgent.test.ts`, `copilotAgentSession.test.ts`, `copilotPluginConverters.test.ts`, `copilotShellTools.test.ts` (20× `bashTool.handler` → `bashTool.handler!`).

Deb-build follow-up (`dced3b17d10`):

- `build/linux/debian/dep-lists.ts`: amd64 `libc6 (>= 2.14)` → `libc6 (>= 2.15)`. New `runtime.node` (Bun isolate prebuilt) references `GLIBC_2.15`. Confirmed via `objdump -T … | grep -oE 'GLIBC_[0-9.]+' | sort -u`. Overall package floor stays at `>= 2.28`; this is allowlist bookkeeping, not a distro-support change.

Lockfile fix (`aef1a1d9f71`):

- `remote/package-lock.json` had a broken stub `node_modules/@github/copilot/node_modules/@github/copilot-win32-x64` with no `version` field that crashed `npm install` with `TypeError: Invalid Version:` in `Node.canDedupe`. Replaced with a proper top-level `node_modules/@github/copilot-win32-x64@1.0.55-3` entry. Probable cause: messy `npm install` interaction between `min-release-age` and the SDK's nested CLI optionalDependencies.

## Validation

| Check | Status |
|---|---|
| `npm install` (root + `remote/`) | ✅ |
| `npm run compile-check-ts-native` | ✅ 0 errors |
| `npm run valid-layers-check` | ✅ |
| `node build/next/index.ts transpile` | ✅ |
| Agent host unit tests (1357 cases) | ✅ |
| Real-SDK integration tests (`AGENT_HOST_REAL_SDK=1`) | ⚠️ 9/11 (2 known failures, see below) |
| Live launch via launch skill + Playwright over CDP | ✅ agent host spawns, authenticates, accepts messages, no SDK exceptions in renderer/agent-host logs |
| Azure DevOps `vscode-linux-x64-prepare-deb` step | ✅ after `dced3b17d10` (failed in buildId 443000 before the fix) |

### Known real-SDK failures (carried as follow-up; not blocking)

1. **`planning-mode session-state writes are auto-approved in default mode`** — 90s timeout. The plan-mode shim in `copilotAgent.ts::_enablePlanModeOnClient` reaches through the SDK's private `client.connection`, which still exists in beta.8 but now coexists with a new public `SessionConfig.onExitPlanModeRequest` / `onAutoModeSwitchRequest`. The in-code comment already says to migrate when public surface lands — that day has arrived. The SDK's new `ExitPlanModeResult` type drops `autoApproveEdits`, though the underlying CLI wire schema still accepts it.
2. **`subagent tool calls are routed to the subagent session, not flat in the parent`** — parent session now contains a `read_agent` tool call. May be a CLI 1.0.55-3 behavior shift (CLI 1.0.49 did not surface `read_agent` to the parent) or a real routing regression. Needs investigation in a follow-up.

## Retrospective — what went wrong (so future bumps go smoother)

1. **The deb auto-deps allowlist check (`vscode-linux-x64-prepare-deb`) runs only on Azure DevOps, not GitHub Actions PR CI.** I checked `gh pr checks` saw all-green, declared the bump done, and the deb failure surfaced ~16h later. Past nine `@github/copilot` bumps (1.0.24 → 1.0.49) never touched `dep-lists.ts`; this is the first prebuilt-native-module bump where the embedded Bun isolate's GLIBC tier moved. Captured as gotchas on both [copilot-agent-provider](../../docs/copilot-agent-provider.md#debt--gotchas) (provider-specific: how to diagnose with `objdump -T`) and [testing](../../docs/testing.md#debt--gotchas) (cross-cutting: the CI surface gap).

2. **The existing "track `extensions/copilot/package.json`" gotcha didn't survive contact with an SDK peer-dep bump.** It said the CLI should always follow the extension's pin; the SDK at beta.8 declared `^1.0.55-1` and we had to bump past `1.0.49` to install. Reworded the gotcha to call out the exception rather than letting future agents trust the old absolute rule.

3. **`min-release-age=1` in `remote/.npmrc` silently capped "latest".** Not noted anywhere in the knowledge base before. Worth knowing because `npm view <pkg> version` returns one number while the install resolves a different one, with no obvious diagnostic in npm's output. Captured in this summary; left out of the per-doc gotchas because the right fix would be a brief paragraph somewhere about how this repo's npmrc shapes "latest" — out of scope for this session.

4. **Two-commit PR.** The first push had a broken `remote/package-lock.json` stub that crashed CI on `npm install`. The combination of `min-release-age` + the SDK's nested `optionalDependencies` for `@github/copilot-<platform>` packages produced a `package-lock.json` entry without a `version` field that `Node.canDedupe` chokes on. Fixed in `aef1a1d9f71`. Avoidable next time by running `rm -rf node_modules remote/node_modules && npm install` cleanly in both before pushing rather than trusting in-place updates.

5. **AzDo log access friction.** Azure DevOps build logs require organizational auth; `web_fetch` only returned the sign-in page, and `gh pr checks` showed the failing job name but not the log body. Had to ask the user to paste the failing chunk. Noted in the testing gotcha.

## Files changed (excluding lockfiles)

- `package.json`, `remote/package.json` — version bumps
- `build/linux/debian/dep-lists.ts` — `libc6 (>= 2.15)` for amd64
- `src/vs/platform/agentHost/common/agentService.ts` — extended `permissionKind` union
- `src/vs/platform/agentHost/node/copilot/copilotAgent.ts` — `connection: RuntimeConnection.forStdio`, `enableRemoteSessions`, `workingDirectory`
- `src/vs/platform/agentHost/node/copilot/copilotAgentSession.ts` — `getEvents`, `disconnect`, dropped `copilotUsage`
- `src/vs/platform/agentHost/node/copilot/copilotSessionWrapper.ts` — `disconnect`
- `src/vs/platform/agentHost/node/copilot/copilotToolDisplay.ts` — `ITypedPermissionRequest` standalone interface
- `src/vs/platform/agentHost/test/node/copilotAgent.test.ts`
- `src/vs/platform/agentHost/test/node/copilotAgentSession.test.ts`
- `src/vs/platform/agentHost/test/node/copilotPluginConverters.test.ts`
- `src/vs/platform/agentHost/test/node/copilotShellTools.test.ts`

## Related

- [copilot-agent-provider](../../docs/copilot-agent-provider.md) — the provider doc this session updated.
- [testing](../../docs/testing.md) — the CI-surfaces gotcha lives here.
- [changes/2026-04-28-bump-copilot-1.0.38](../2026-04-28-bump-copilot-1.0.38/summary.md), [changes/2026-04-22-bump-copilot-1.0.34-with-wrapper](../2026-04-22-bump-copilot-1.0.34-with-wrapper/summary.md), [changes/2026-04-21-update-copilot-sdk-versions](../2026-04-21-update-copilot-sdk-versions/summary.md) — precedent SDK / CLI bumps.
