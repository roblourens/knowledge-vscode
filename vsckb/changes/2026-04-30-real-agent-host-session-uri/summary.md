# Real Agent Host Session URIs

Date: 2026-04-30

VS Code branch: `roblou/troubled-gibbon`

VS Code SHA: `928bc0340d`

PR: [#313622](https://github.com/microsoft/vscode/pull/313622)

## What Changed

Agent Host chat sessions no longer use `/untitled-*` resources as Agent Host-owned session resources. New sessions are assigned final-looking resources before the Agent Host handler/provider owns them, and the raw path segment of that resource is the backend raw session id.

The client now determines the URI for a chat session over AHP. On the VS Code side, the URI is created in one of the owner paths:

- The Sessions app provider path uses `BaseAgentHostSessionsProvider._createNewSessionForType(...)` to create a host-specific resource scheme plus `/<uuid>` path, then marks the adapter as `SessionStatus.Untitled` until the backend session list confirms it.
- The workbench contributed-chat first-send path uses `IChatSessionItemController.newChatSessionItem`. For local Agent Host, `AgentHostSessionListController.newChatSessionItem(...)` chooses the real `agent-host-${provider}:/<uuid>` resource before the request reaches `AgentHostSessionHandler`.

`AgentHostSessionHandler` now derives `AgentSession.uri(provider, rawId)` directly from the chat resource and passes it as `createSession({ session, ... })`. The old handler-side UI-resource-to-backend-resource map is gone. If a backend or remote client returns a different URI for non-fork creation, that is a contract violation.

## Key Decisions

- `/untitled-*` is a generic chat-service staging shape only. If `agent-host-*:/untitled-*` reaches the Agent Host content provider, that is a bug.
- Draft-ness is explicit state, not a path convention. Providers use `SessionStatus.Untitled`; the workbench list controller tracks pending ids created by `newChatSessionItem`.
- `newChatSessionItem` returns a routing handle, not a visible list row. The visible row is inserted only after backend confirmation through `notify/sessionAdded` or `listSessions()` reconciliation.
- `ISession.sessionType` remains the logical agent provider id, while the resource scheme remains host-specific. New-session resolver registration must use the resource scheme.
- Same-id draft-to-committed replacement is a change, not a removal. Consumers that clean up on removal must not see a same-id replacement as ownership loss.

## What Went Wrong or Was Misunderstood

- I initially treated generic `/untitled-*` contributed-chat resources as something the handler should tolerate. Rob correctly pushed back: Agent Host should only handle session resources it created and owns. The docs now record that `agent-host-*:/untitled-*` in the handler/provider path is a bug.
- The first `newChatSessionItem` implementation inserted a visible list item before backend create succeeded. Review caught the phantom-row failure mode. The controller now keeps pending ids separate and waits for backend confirmation before mutating `_items`.
- The same-id replacement event initially emitted a removal, which could trigger downstream cleanup such as terminal disposal. The lifecycle docs now call out that same-id replacement must not remove.
- The remote client initially ignored `config.session` and generated its own URI. That broke the client-owned URI contract and is now documented in the remote protocol client notes.
- Scheme mapping is load-bearing: the logical provider id (`copilotcli`) is not the same as the chat resource scheme (`agent-host-copilotcli` or the remote scheme). Resolver registration and content-provider routing must use the resource scheme.

## Docs Updated

- [agent-host-session-handler](../../docs/agent-host-session-handler.md) now documents chat-session URI ownership, the `newChatSessionItem` path, explicit draft predicates, and the handler's requested-session contract.
- [agent-host-sessions-providers](../../docs/agent-host-sessions-providers.md) now documents the new-session URI lifecycle for Sessions app providers and the local workbench list controller, plus gotchas for no `/untitled-*` resources, no phantom rows, and same-id replacement.
- [agent-host-remote-protocol-client](../../docs/agent-host-remote-protocol-client.md) now documents that remote `createSession(config.session)` must honor the client-requested URI.
- [index](../../index.md) now has a cross-cutting gotcha for no Agent Host `/untitled-*` resources.
