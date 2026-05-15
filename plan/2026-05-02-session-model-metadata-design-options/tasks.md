# Tasks

- [x] Trace extension-host CLI model multiplier source — found `model.billing?.multiplier` from private SDK `getAvailableModels(authInfo)`.
- [x] Thread agent-host model `_meta` through provider/root-state/UI mapping.

## Discoveries for finalize
- docs/agent-host-protocol.md: new bidirectional `resourceRequest` in the synced protocol requires a server-side `RequestHandlerMap` entry in `protocolServerHandler.ts`; current doc does not mention this handler obligation.