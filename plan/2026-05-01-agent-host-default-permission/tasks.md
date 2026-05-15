# Agent host: respect `chat.permissions.default`

- [x] Inject `IConfigurationService` into `BaseAgentHostSessionsProvider`; thread through `LocalAgentHostSessionsProvider` and `RemoteAgentHostSessionsProvider` `super(...)` calls.
- [x] In `_createNewSessionForType`, seed the new-session config bag with `{ autoApprove: <chat.permissions.default> }` (only when the configured value is one of `default | autoApprove | autopilot`) and pass it as the `config` argument to the first `resolveSessionConfig` round-trip.
  - note: matches existing behavior in `CopilotChatSessionsProvider.createNewChat` (no policy clamp at config-storage time — the picker UI handles policy clamp at render).
  - note: hosts that don't advertise `autoApprove` ignore the unknown key per AHP, so this is safe across agents.

## Discoveries for finalize
- doc: `agent-host-sessions-providers.md` — should mention that base provider seeds initial new-session config from `chat.permissions.default` for the well-known `autoApprove` key.
