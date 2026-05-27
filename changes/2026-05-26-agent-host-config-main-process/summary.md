# Register chat.agentHost.* settings outside the renderer

**Date:** 2026-05-26
**VS Code branch:** agents/vsckb-implement-the-agenthost-enabled-setting-ne-ef3c91c7
**VS Code SHA at finalize:** fd3be52b6c
**PR:** https://github.com/microsoft/vscode/pull/318487 (draft)

## What was done

`chat.agentHost.*` settings used to be registered only in
`src/vs/workbench/contrib/chat/browser/chat.shared.contribution.ts` (renderer
side), even though several keys were read in non-renderer processes:

- `src/vs/code/electron-main/app.ts` reads `chat.agentHost.enabled` via
  `isAgentHostEnabled()` to decide whether to spawn the agent host.
- `electronAgentHostStarter.ts` and `nodeAgentHostStarter.ts` read
  `chat.agentHost.claudeAgent.path` and the six `chat.agentHost.otel.*`
  settings to populate env vars on the spawned agent host process.

Because `IConfigurationRegistry` is per-process and registrations done in the
renderer don't propagate, every `getValue()` call from those non-renderer
sites was returning `undefined` and the declared defaults were silently
ignored.

This session moved the relevant registrations into two platform-level
contribution files under `src/vs/platform/agentHost/common/`:

- `agentHost.config.contribution.ts` — registers `chat.agentHost.enabled` only.
  Side-effect-imported by `electronAgentHostStarter.ts` (so it travels into
  the main process via `app.ts`'s import of the starter class) and by
  `chat.shared.contribution.ts` (renderer settings UI).
- `agentHostStarter.config.contribution.ts` — registers the seven
  starter-consumed keys. Side-effect-imported by both
  `electronAgentHostStarter.ts` and `nodeAgentHostStarter.ts` (so the
  registration travels with the consumer in main and server), and by
  `chat.shared.contribution.ts`.

The three renderer-only keys (`chat.agentHost.ipcLoggingEnabled`,
`chat.agentHost.ahpJsonlLoggingEnabled`,
`chat.agentHost.customTerminalTool.enabled`) stay inline in
`chat.shared.contribution.ts` — they have no consumers outside the renderer.

`chat.agentHost.clientTools` also stays inline in `chat.shared.contribution.ts`
because its default depends on `browserChatToolReferenceNames`
(workbench-layer data).

## Key decisions

- **Split into two contribution files, not one.** The remote server reads the
  starter keys but never reads `chat.agentHost.enabled` — its spawn decision
  comes from `--agent-host-port` / `--agent-host-path` CLI args. Keeping
  `enabled` out of the server's registry means any accidental future read
  fails loud (returns `undefined`) instead of silently picking up a
  workbench-only default. This applies the design-principles maxim
  "Fail explicitly for contract violations" to the configuration registry
  layer.
- **Side-effect-import the contribution file from the consumer, not the
  process entry.** The first cut imported both files from
  `src/vs/code/electron-main/main.ts` and `src/vs/server/node/server.main.ts`,
  far from where the values are read. Final form side-effect-imports the
  contribution at the top of the starter file that reads the values, so the
  wiring is discoverable from either end.
- **Did NOT replicate workbench settings into the agent host process.**
  Confirmed that the agent host process itself does not read `chat.agentHost.*`
  via workbench `IConfigurationService`. Starters translate settings into env
  vars (`buildAgentHostOTelEnv`, `VSCODE_AGENT_HOST_CLAUDE_SDK_PATH`) and
  runtime knobs flow through the agent-host's own root/session config service.
  Extending that contract is the right way to surface a host-process-internal
  setting, not bolting on a workbench `ConfigurationService`.

## What went wrong or was misunderstood

- **Wrong initial assumption that settings registered in
  `chat.shared.contribution.ts` were visible everywhere.** This is the
  fundamental shape of the bug being fixed: the configuration registry is
  per-process, and the renderer-only registration is invisible to main and
  server. Nothing in the existing docs covered this — it bit because the
  pattern of `chat.shared.contribution.ts` accumulating every `chat.*` setting
  looked authoritative. **Prevented by:** new gotcha on
  `agent-host-topology.md` and a new bullet in its where-to-put-new-code
  decision tree; cross-cutting pointer added to `index.md`.
- **First implementation registered all settings in the server's registry,
  not just the ones it reads.** User pushed back ("just the ones that are
  needed"). The mistake was treating the registration as "a side-effect that
  doesn't hurt anything" rather than as a contract surface. Sharper
  application of "Fail explicitly for contract violations" would have made
  this obvious from the start. **Prevented by:** the new gotcha explicitly
  spells out that the server intentionally does not register
  `chat.agentHost.enabled`.
- **First implementation put the side-effect import at the top of
  `main.ts` / `server.main.ts`, far from the consumer.** User asked for
  "closer to the agent host code in the main process". The starter file
  was the natural home — anyone reading the starter sees the settings it
  consumes registered above. **Prevented by:** the new gotcha + decision-tree
  item both call out co-locating the side-effect import with the consumer
  file.
- **No surprises in the agent host process itself.** The user's intuition
  ("are any read in the agent host process itself, I don't think so, that
  seems wrong, please check briefly") was correct — the starter env-var
  translation handles the seven starter keys, and runtime knobs flow through
  the agent-host's own config service. Documenting this explicitly in the
  new gotcha guards against a future agent "fixing" the absence by injecting
  a workbench `IConfigurationService` into the host process.

## What we learned

- The `update.config.contribution.ts` pattern (in
  `src/vs/platform/update/common/`) was the model for the new files: a
  side-effect-import config file at the platform layer, imported by each
  process that needs the defaults. Useful precedent to remember when a
  workbench-style setting needs to be visible across processes.
- Side-effect imports of contribution files survive bundling in this
  codebase — module-level `Registry.as<IConfigurationRegistry>(...).registerConfiguration({...})`
  calls are not pruned. The VS Code codebase relies on this pattern
  extensively for contribution registration.

## Doc updates

- `docs/agent-host-topology.md`:
  - Added a new decision-tree item (now §3 item 6) for workbench settings
    consumed outside the renderer. Renumbered subsequent items.
  - Added a new gotcha covering the per-process `IConfigurationRegistry`,
    the split between `agentHost.config.contribution.ts` and
    `agentHostStarter.config.contribution.ts`, why the remote server
    intentionally does not register `chat.agentHost.enabled`, and the fact
    that the agent host process does not read these via workbench
    `IConfigurationService`.
  - Changelog entry added.
- `index.md`:
  - Added cross-cutting `gotcha (workbench-setting registration is
    per-process)` pointer under `## Active debt & gotchas`.

No new docs; no removed `debt:` entries.
