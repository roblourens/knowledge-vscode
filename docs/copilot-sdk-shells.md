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

- **gotcha** (2026-05-26, terminal-tool output rendering) — ANSI color / SGR / bold escape sequences in terminal-tool stdout are **stripped** before they reach both the rendered tool card and the model. Output like `printf '\033[31mRED\033[0m \033[1mBOLD\033[0m'` shows up as plain `RED BOLD` in the chat UI, and the agent itself describes seeing "escape codes stripped". Codes aren't visible as raw `\033[…m` (so it's not just a render-as-text bug) — the strip happens somewhere on the path from SDK shell tool → AHP terminal action → display. Tools whose value depends on color (lint output, `git --color=always`, jest/mocha runners) lose their visual structure both for the user and for the model's interpretation. May be intentional given the SDK's default terminal pipeline; consider whether the `chat.agentHost.customTerminalTool.enabled` path should preserve or render ANSI. Bug-bash evidence: `files/bug-bash/s7/`.
- **gotcha** (2026-04-22, copilotShellTools.ts:createShellTools) — secondary shell tools (`read_bash` / `write_bash` / `stop_bash` / `list_bash` and PowerShell variants) registered with `overridesBuiltInTool: true` MUST also set `skipPermission: true` to match the SDK's built-in behavior, where these helpers never call `permissions.request`. Without the flag, Agent Host raises a generic permission dialog for every `write_bash` etc., which is jarring (the upstream CLI/extension never ask). The display layer's permission rendering for these tools (`copilotToolDisplay.ts`) is now defense-in-depth — it ships nice fields if a request ever leaks through. Regression coverage: `copilotShellTools.test.ts:'shell helper tools (read/write/shutdown/list/redirect) are registered with skipPermission: true'`.
- **gotcha** (2026-04-19, copilotShellTools.ts:executeCommandWithShellIntegration/executeCommandWithSentinel) — for bash/zsh managed shells, commands are prepended with a leading space to keep them out of shell history. This relies on `VSCODE_PREVENT_SHELL_HISTORY=1` being set on the PTY env (which the shell integration scripts translate to `HISTCONTROL=ignorespace`/`HIST_IGNORE_SPACE`). If you change either side independently, history suppression silently breaks. PowerShell intentionally has no prefix — PSReadLine handles it server-side.
- **gotcha** (2026-07-01, copilotShellTools.ts:parseSentinel) — the sentinel parser scans **backwards** (`lastIndexOf`) for the last complete numeric exit-code marker, not forwards for the first match. Some shells echo the sentinel command text itself (e.g. the literal `<<<COPILOT_SENTINEL_..._EXIT_$?>>>`) into stdout before the real numeric marker arrives; a forward first-match scan would parse the echoed, non-numeric marker and misreport the exit code. If you touch this function, keep the backward scan and the non-numeric-marker skip — don't revert to a single forward `indexOf`.

## Related

- [copilot-agent-provider](./copilot-agent-provider.md) — provider lifecycle and session ownership.
- [copilot-sdk-permissions](./copilot-sdk-permissions.md) — permission callback behavior outside shell tools.
- [copilot-sdk-tool-display](./copilot-sdk-tool-display.md) — shell command display rewriting and permission display.

## Sandboxed shell execution

Managed shell tools can now run inside a **sandbox**. The engine lives in `agentHostSandboxEngine.ts` (`AgentHostSandboxEngine`, `createAgentHostSandboxEngine`), built on the shared `TerminalSandboxEngine` / `ISandboxHelperService`, with config via `AgentHostSandboxConfigKey` / `sandboxConfigSchema` (`sandboxSettingIdToAgentHostKey`) and SDK wiring in `sandboxConfigForSdk.ts`. The earlier `autoApproveUnsandboxed` config field was **removed** — auto-approval no longer keys off a sandbox boolean; sandboxing is now its own per-session config surface.

Sandboxing is now gated by **approval mode**, not just settings: `CopilotAgentSession._isBypassApprovals()` returns true when global auto-approve is enabled (`AgentHostGlobalAutoApproveEnabledConfigKey`), autopilot mode is active, or the session's `autoApprove` setting is `'autoApprove'`; `_computeSdkSandboxConfig()` returns `undefined` (no sandbox) in that case or when the host terminal tool override is active (`_isCustomTerminalToolEnabled()`). `_applyEffectiveSandboxConfig()` re-pushes the effective config via `session.rpc.options.update({ sandboxConfig })` before **every** `send()` — sandbox config is per-request now, not fixed once at session launch, so it can never go stale across an approval-mode change mid-session. `buildSandboxConfigForSdk()` also short-circuits on Windows: `WINDOWS_SANDBOX_SUPPORTED` is a hardcoded `false` gate (Windows sandboxing support is deferred but the branches are kept exercisable so it can be flipped on later without a rewrite).

The SDK sandbox can also be **bypassed per-command**: `buildSandboxConfigForSdk()` unconditionally sets `ISdkSandboxConfig.allowBypass: true`, and a shell command's permission signal can carry `requestSandboxBypass: true` (on `IToolApprovalEvent` and the display-layer `ITypedPermissionRequest`). `getAutoApproval()` checks `requestSandboxBypass` first and returns `undefined` (no auto-approval, but also no sandbox) so the command runs unsandboxed by explicit request. When a bypass is requested, `copilotToolDisplay.ts`'s `getPermissionDisplay()` swaps the shell confirmation title to "Run in terminal outside the sandbox?" instead of "Run in terminal?" so the user knows what they're approving. Note: network host allow/deny lists (`AllowedNetworkDomains`/`DeniedNetworkDomains`) are currently **not enforced on any platform** — `hostListsEnforceable` is hardcoded `false` in `sandboxConfigForSdk.ts` because the runtime doesn't reliably enforce them everywhere yet; a standalone `AgentHostSandboxKey.AllowNetwork` toggle now exists alongside the legacy `allowNetwork` enum value for the overall sandbox-enabled setting.

## Changelog

- **2026-07-02** — f9f2fd558a — reconciliation: expanded **Sandboxed shell execution** with approval-mode gating (`_isBypassApprovals`/`_computeSdkSandboxConfig`/`_applyEffectiveSandboxConfig`, per-request not per-session config push), the Windows `WINDOWS_SANDBOX_SUPPORTED` dead-code gate, per-command sandbox bypass (`allowBypass`/`requestSandboxBypass`, bypass confirmation title), the still-unenforced host network lists (`hostListsEnforceable = false`), and the new standalone `AgentHostSandboxKey.AllowNetwork` toggle. Added a gotcha for the `parseSentinel()` backward-scan rewrite that handles echoed sentinel text. Shell exit-code decorations now come from SDK `shell_exit` content — documented in [copilot-sdk-tool-display](./copilot-sdk-tool-display.md), not here, since the consuming code (`mapSessionEvents.ts`, `stateToProgressAdapter.ts`) is outside this doc's `Covers:`. Commits: `a91385696d0`, `c0cc253a971`, `a68095a2946`, `4b6f5e55bb8`.

- **2026-06-25** — 09c18fe5c5 — reconciliation: added a **Sandboxed shell execution** section (`agentHostSandboxEngine.ts` / `AgentHostSandboxEngine` / `createAgentHostSandboxEngine` on the shared `TerminalSandboxEngine` / `ISandboxHelperService`; `AgentHostSandboxConfigKey` / `sandboxConfigSchema` / `sandboxConfigForSdk.ts`); the `autoApproveUnsandboxed` field was removed. Managed-shell-tool and shell-history-suppression prose is otherwise unchanged.

- **2026-05-26** — e6e488e018 — bug bash recorded that ANSI color/SGR escape codes in terminal-tool output are stripped before reaching the chat UI or the model. Noted as a gotcha; see `changes/2026-05-26-agent-host-terminal-tool-bug-bash/`.

- **2026-05-15** — 12443ea83d — reconciliation: refreshed permission-regression coverage to the current focused shell-tools test after the real-SDK suite split in `0d23db45a18`; zsh/alt-buffer and shell-guidance changes in the covered area did not change the managed-shell permission architecture.

- **2026-05-04** — 939d3f227c — reconciliation: no body changes. `e1a89568eb2` only updated the real-SDK test harness to the new protocol handshake shape; managed shell behavior, `skipPermission`, and history suppression are unchanged.

- **2026-05-01** — b2e6267136 — reconciliation: documented independent terminal allocation for concurrent primary shell calls after `cfa5454b64c5`; `b9acc7f21912` only changed terminal-tool instructions, not shell-tool architecture.
- **2026-04-24** — 4b6403a3ab — split managed shell behavior, permission asymmetry, and history suppression out of the Copilot provider overview
