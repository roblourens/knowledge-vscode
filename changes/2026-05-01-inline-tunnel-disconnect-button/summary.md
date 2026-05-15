# Inline tunnel disconnect button and suppression

**Date:** 2026-05-02
**VS Code branch:** roblou/agents/add-inline-disconnect-button-tunnels
**VS Code SHA at finalize:** b61ea2452e
**PR:** [#313800](https://github.com/microsoft/vscode/pull/313800)

## What was done

The Sessions workspace picker and Manage Remote Agent Hosts picker now expose the same inline remove/X affordance for remote Agent Hosts, including tunnel-backed hosts. The X path and the per-remote "Remove Remote" action share the same removal helper so tunnel providers get their provider-owned disconnect hook instead of being bypassed through the generic remote host service.

Tunnel disconnect is now remembered as user intent. Explicitly disconnecting a tunnel persists an auto-connect suppression marker, filters that tunnel out of provider reconciliation, and prevents startup/background reconnect from re-adding it to the workspace picker as a transient "Connecting" then "Offline" row. Explicitly choosing the tunnel again clears suppression and lets it reconnect normally.

## Key decisions

- Treat the inline X as semantically identical to "Remove Remote". There should not be a lightweight UI-only removal path for remote Agent Hosts because tunnels need provider-owned cleanup and persisted disconnect intent.
- Keep cached tunnel discovery separate from provider visibility. A suppressed tunnel can remain in the recent/discovery cache for the tunnel picker, but it should not become an `IAgentHostSessionsProvider` until the user explicitly reconnects.
- Keep the post-connect suppression guard for background connects. It looks redundant next to the pre-check, but covers the race where the user disconnects while a startup/background connect is already awaiting the tunnel service.
- Clear suppression at the start of an explicit reconnect attempt. If the user tries to reconnect and the attempt fails transiently, the old disconnect marker should not block later retries.

## What went wrong or was misunderstood

- The initial issue description assumed only tunnels lacked the inline X, but main had changed so neither SSH nor tunnels rendered it. The actual bug was that flattened workspace-picker actions dropped ad-hoc `onRemove` state. — **prevented by:** the [remote-agent-host-management-ux](../../docs/remote-agent-host-management-ux.md) doc now covers the workspace-picker inline remove path and shared remove helper.
- The first inline X implementation had different behavior from "Remove Remote" and bypassed tunnel-owned disconnect semantics. — **prevented by:** a `gotcha:` on [remote-agent-host-management-ux](../../docs/remote-agent-host-management-ux.md#debt--gotchas) says both paths must use `removeRemoteHost(...)`.
- Suppressed tunnels still appeared after reload as "Connecting" then "Offline" because cached tunnels were registered as providers before suppression was considered. — **prevented by:** the tunnel-backed provider section and `gotcha:` entries in [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md#tunnel-backed-remote-providers) record that suppressed cached tunnels must be filtered before provider registration.
- A review comment questioned the post-connect suppression check because the pre-check already existed. The missing context was the in-flight background connect race. — **prevented by:** a `gotcha:` on [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md#debt--gotchas) explicitly preserves both checks.
- The finalize workflow initially treated unrelated untracked plan folders as a blocker. In this repo shape, unrelated session plans can coexist. — **prevented by:** the `finalize` skill now documents that user-confirmed unrelated plan folders can be ignored, but only with explicit staging instead of `git add -A`.

## What we learned

- Tunnel auto-connect is started by `TunnelAgentHostContribution` after restore via rediscovery / silent status check, guarded by `chat.remoteAgentHostsAutoConnect`.
- Code OSS has tunnel plumbing, but desktop OSS lacks the product tunnel application config/scopes and web needs an embedder-supplied tunnel discovery provider.
- Shared platform UI helpers such as `ActionList` need async remove support when the remove operation has provider-side state effects.

## Doc updates

- Updated `docs/remote-agent-host-management-ux.md` with workspace-picker inline remove semantics, shared `removeRemoteHost(...)` / `reconnectRemoteHost(...)` helpers, async ActionList removal, and one new gotcha.
- Updated `docs/agent-host-sessions-providers.md` with tunnel-backed provider lifecycle, suppression persistence, provider filtering, background-connect race handling, explicit reconnect suppression clearing, and three new gotchas.
- Updated `index.md` with a cross-cutting active gotcha for tunnel disconnect suppression.
- Updated `skills/finalize/SKILL.md` to allow ignoring user-confirmed unrelated plan folders while requiring explicit staging.
