# Copilot SDK Shells

_Covers: src/vs/platform/agentHost/node/copilot/copilotShellTools.ts, src/vs/platform/agentHost/test/node/copilotShellTools.test.ts_

`copilotShellTools.ts` provides Agent Host's Copilot SDK shell-tool integration. It registers managed bash/PowerShell tools backed by `IAgentHostTerminalManager` PTYs so commands run inside VS Code's terminal infrastructure rather than detached child processes.

## Managed shells

`ShellManager` provides per-session persistent bash/PowerShell shells backed by `IAgentHostTerminalManager` PTYs. The shells override the SDK's built-in shell tools (`overridesBuiltInTool: true`) so commands run inside our terminal infrastructure with shell integration and the AHP terminal subscription.

Primary `bash` / `powershell` calls acquire an exclusive shell reference through `getOrCreateShell(...)`. An idle shell of the right type can be reused, but a shell running a command is tracked in `_busyShellIds` and skipped so concurrent primary tool calls get independent terminals instead of interleaving input/output in the same PTY. `read_*`, `write_*`, `list_*`, and shutdown helpers operate on existing shells and keep `skipPermission: true` as described below.

## Permission asymmetry

Secondary shell tools must set `skipPermission: true`. The SDK's built-in `read_bash` / `write_bash` / `stop_bash` / `list_bash` (and PowerShell variants) never call `permissions.request` — verified in `node_modules/@github/copilot/sdk/index.js`. Only the primary `bash` / `powershell` tool prompts. So in the upstream Copilot CLI and the in-tree extension, users never see a dialog for these helpers because the SDK never asks.

When Agent Host re-registers them as external tools (`overridesBuiltInTool: true`), they default to requiring permission because external tools route through `requestPermissionWithHooks` unless they opt out. To match the CLI/extension behavior, each helper must declare `skipPermission: true` on its `Tool` descriptor. The SDK type at `node_modules/@github/copilot/sdk/index.d.ts` documents the field as "When true, the tool can execute without a permission prompt." The focused `copilotShellTools.test.ts` regression (`shell helper tools (read/write/shutdown/list/redirect) are registered with skipPermission: true`) catches accidental removal of the flag.

## Shell history suppression

Managed shells are always created with `preventShellHistory: true`, which sets `VSCODE_PREVENT_SHELL_HISTORY=1` on the PTY env. The existing shell integration scripts in `src/vs/workbench/contrib/terminal/common/scripts/` interpret that to enable `HISTCONTROL=ignorespace` (bash), `HIST_IGNORE_SPACE` (zsh), or a no-op PSReadLine `AddToHistoryHandler`.

For bash/zsh, command lines written via `executeCommandWithShellIntegration` and `executeCommandWithSentinel` are also prepended with a single space (`prefixForHistorySuppression`) so they actually hit the env-var-controlled exclusion. PowerShell needs no prefix because PSReadLine drops everything. This mirrors the workbench's `chat.tools.terminal.preventShellHistory` behavior in `toolTerminalCreator.ts` + `commandLinePreventHistoryRewriter.ts`, but is unconditional on the Agent Host side (no setting yet).

## Debt & gotchas

- **gotcha** (2026-04-22, copilotShellTools.ts:createShellTools) — secondary shell tools (`read_bash` / `write_bash` / `stop_bash` / `list_bash` and PowerShell variants) registered with `overridesBuiltInTool: true` MUST also set `skipPermission: true` to match the SDK's built-in behavior, where these helpers never call `permissions.request`. Without the flag, Agent Host raises a generic permission dialog for every `write_bash` etc., which is jarring (the upstream CLI/extension never ask). The display layer's permission rendering for these tools (`copilotToolDisplay.ts`) is now defense-in-depth — it ships nice fields if a request ever leaks through. Regression coverage: `copilotShellTools.test.ts:'shell helper tools (read/write/shutdown/list/redirect) are registered with skipPermission: true'`.
- **gotcha** (2026-04-19, copilotShellTools.ts:executeCommandWithShellIntegration/executeCommandWithSentinel) — for bash/zsh managed shells, commands are prepended with a leading space to keep them out of shell history. This relies on `VSCODE_PREVENT_SHELL_HISTORY=1` being set on the PTY env (which the shell integration scripts translate to `HISTCONTROL=ignorespace`/`HIST_IGNORE_SPACE`). If you change either side independently, history suppression silently breaks. PowerShell intentionally has no prefix — PSReadLine handles it server-side.

## Related

- [copilot-agent-provider](./copilot-agent-provider.md) — provider lifecycle and session ownership.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) — permission callback behavior outside shell tools.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — shell command display rewriting and permission display.

## Changelog

- **2026-05-15** — 12443ea83d — reconciliation: refreshed permission-regression coverage to the current focused shell-tools test after the real-SDK suite split in `0d23db45a18`; zsh/alt-buffer and shell-guidance changes in the covered area did not change the managed-shell permission architecture.

- **2026-05-04** — 939d3f227c — reconciliation: no body changes. `e1a89568eb2` only updated the real-SDK test harness to the new protocol handshake shape; managed shell behavior, `skipPermission`, and history suppression are unchanged.

- **2026-05-01** — b2e6267136 — reconciliation: documented independent terminal allocation for concurrent primary shell calls after `cfa5454b64c5`; `b9acc7f21912` only changed terminal-tool instructions, not shell-tool architecture.
- **2026-04-24** — 4b6403a3ab — split managed shell behavior, permission asymmetry, and history suppression out of the Copilot provider overview
